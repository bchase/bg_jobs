import bg_jobs/internal/utils
import bg_jobs/jobs
import bg_jobs/postgres_db_adapter
import gleam/string

// used for the decoders
import birl
import birl/duration
import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/order
import gleam/pgo
import gleeunit/should
import test_helpers

const job_name = "test-job"

const job_payload = "test-payload"

pub fn new_db() {
  let assert Ok(config) =
    pgo.url_config(
      "postgres://postgres:mySuperSecretPassword!@localhost:5432/postgres?sslmode=disable",
    )
  let db = pgo.connect(pgo.Config(..config, pool_size: 1))
  let assert Ok(_) = postgres_db_adapter.migrate_down(db)()
  let assert Ok(_) = postgres_db_adapter.migrate_up(db)()
  db
}

pub fn enqueue_job_test() {
  let conn = new_db()
  let job_store = postgres_db_adapter.new(conn, [fn(_) { Nil }])

  let assert Ok(returned_job) =
    job_store.enqueue_job(
      job_name,
      job_payload,
      birl.now() |> birl.to_erlang_datetime(),
    )
  process.sleep(100)

  let assert Ok(pgo.Returned(count, jobs)) =
    pgo.execute(
      "SELECT * FROM jobs;",
      conn,
      [],
      postgres_db_adapter.decode_enqueued_db_row,
    )

  count
  |> should.equal(1)

  list.first(jobs)
  |> should.be_ok
  |> fn(job) {
    should.equal(returned_job, job)

    validate_job(job, job_name, job_payload)

    job.reserved_at
    |> should.be_none
  }
}

pub fn claim_jobs_limit_test() {
  let conn = new_db()
  let job_store = postgres_db_adapter.new(conn, [fn(_) { Nil }])

  let assert Ok(_returned_job1) =
    job_store.enqueue_job(
      job_name,
      job_payload,
      birl.now() |> birl.to_erlang_datetime(),
    )

  let assert Ok(_returned_job2) =
    job_store.enqueue_job(
      job_name,
      job_payload,
      birl.now() |> birl.to_erlang_datetime(),
    )

  process.sleep(1000)
  let assert Ok(pgo.Returned(count, _jobs)) =
    pgo.execute(
      "SELECT * FROM jobs;",
      conn,
      [],
      postgres_db_adapter.decode_enqueued_db_row,
    )
  count |> should.equal(2)
  job_store.claim_jobs([job_name], 1, "default_queue")
  |> should.be_ok
  |> list.length
  |> should.equal(1)

  job_store.claim_jobs([job_name], 1, "default_queue")
  |> should.be_ok
  |> list.length
  |> should.equal(1)

  job_store.claim_jobs([job_name], 1, "default_queue")
  |> should.be_ok
  |> list.length
  |> should.equal(0)
}

pub fn claim_jobs_returned_test() {
  let conn = new_db()
  let job_store = postgres_db_adapter.new(conn, [fn(_) { Nil }])

  let assert Ok(_) =
    job_store.enqueue_job(
      job_name,
      job_payload,
      birl.now() |> birl.to_erlang_datetime(),
    )

  job_store.claim_jobs([job_name], 1, "default_queue")
  |> should.be_ok
  |> list.first
  |> should.be_ok
  |> fn(job) {
    validate_job(job, job_name, job_payload)

    job.reserved_at
    |> should.be_some

    job.reserved_by
    |> should.be_some
    |> should.equal("default_queue")
  }
}

pub fn move_job_to_success_test() {
  let conn = new_db()
  let job_store = postgres_db_adapter.new(conn, [fn(_) { Nil }])

  let assert Ok(job) =
    job_store.enqueue_job(
      job_name,
      job_payload,
      birl.now() |> birl.to_erlang_datetime(),
    )

  job_store.move_job_to_succeeded(job)
  |> should.be_ok

  pgo.execute(
    "SELECT * FROM jobs;",
    conn,
    [],
    postgres_db_adapter.decode_enqueued_db_row,
  )
  |> should.be_ok()
  |> fn(returned) {
    let pgo.Returned(count, _rows) = returned
    count |> should.equal(0)
  }

  pgo.execute(
    "SELECT * FROM jobs_succeeded;",
    conn,
    [],
    postgres_db_adapter.decode_succeeded_db_row,
  )
  |> should.be_ok()
  |> fn(returned) {
    let pgo.Returned(count, rows) = returned
    count |> should.equal(1)

    let assert Ok(row) = list.first(rows)

    row
    |> should.equal(jobs.SucceededJob(
      id: job.id,
      name: job.name,
      payload: job.payload,
      attempts: job.attempts,
      created_at: job.created_at,
      available_at: job.available_at,
      succeeded_at: birl.to_erlang_datetime(birl.now()),
    ))
  }
}

pub fn move_job_to_failed_test() {
  let conn = new_db()
  let job_store = postgres_db_adapter.new(conn, [fn(_) { Nil }])

  let assert Ok(job) =
    job_store.enqueue_job(
      job_name,
      job_payload,
      birl.now() |> birl.to_erlang_datetime(),
    )
  job_store.move_job_to_failed(job, "test exception")
  |> should.be_ok

  pgo.execute(
    "SELECT * FROM jobs",
    conn,
    [],
    postgres_db_adapter.decode_enqueued_db_row,
  )
  |> should.be_ok()
  |> fn(returned) {
    let pgo.Returned(count, _rows) = returned
    count |> should.equal(0)
  }

  pgo.execute(
    "SELECT * FROM jobs_failed",
    conn,
    [],
    postgres_db_adapter.decode_failed_db_row,
  )
  |> should.be_ok()
  |> fn(returned) {
    let pgo.Returned(count, rows) = returned
    count |> should.equal(1)
    let assert Ok(row) = list.first(rows)
    row
    |> fn(row: jobs.FailedJob) {
      row.id |> should.equal(job.id)
      row.name |> should.equal(job.name)
      row.payload |> should.equal(job.payload)
      row.attempts |> should.equal(job.attempts)
      row.exception |> should.equal("test exception")
      row.created_at |> should.equal(job.created_at)
      row.available_at |> should.equal(job.available_at)
    }
  }
}

pub fn get_succeeded_jobs_test() {
  let conn = new_db()
  let job_store = postgres_db_adapter.new(conn, [fn(_) { Nil }])

  let assert Ok(_) =
    pgo.execute(
      "INSERT INTO jobs_succeeded (
      id, 
      name, 
      payload, 
      attempts, 
      created_at, 
      available_at, 
      succeeded_at
    )
    VALUES (
      'job_12345',                                 
      'process_order',                             
      '\"test-payload\"',       
      3,                                           
      '2024-09-29 10:30:00',                       
      '2024-09-29 10:30:00',                        
      '2024-09-29 11:00:00'                        
    );
    ",
      conn,
      [],
      utils.discard_decode,
    )

  job_store.get_succeeded_jobs(1)
  |> should.be_ok
  |> should.equal([
    jobs.SucceededJob(
      "job_12345",
      "process_order",
      "\"test-payload\"",
      3,
      #(#(2024, 09, 29), #(10, 30, 00)),
      #(#(2024, 09, 29), #(10, 30, 00)),
      #(#(2024, 09, 29), #(11, 00, 00)),
    ),
  ])
}

pub fn get_failed_jobs_test() {
  let conn = new_db()
  let job_store = postgres_db_adapter.new(conn, [fn(_) { Nil }])

  let assert Ok(_) =
    pgo.execute(
      "INSERT INTO jobs_failed (
      id, 
      name, 
      payload, 
      attempts, 
      exception,
      created_at, 
      available_at, 
      failed_at
    )
    VALUES (
      'job_12345',                                 
      'process_order',                             
      '\"test-payload\"',       
      3,                                           
      'Test exception',
      '2024-09-29 10:30:00',                       
      '2024-09-29 10:30:00',
      '2024-09-29 11:00:00'                        
    );
    ",
      conn,
      [],
      utils.discard_decode,
    )

  job_store.get_failed_jobs(1)
  |> should.be_ok
  |> should.equal([
    jobs.FailedJob(
      "job_12345",
      "process_order",
      "\"test-payload\"",
      3,
      "Test exception",
      #(#(2024, 9, 29), #(10, 30, 0)),
      #(#(2024, 9, 29), #(10, 30, 0)),
      #(#(2024, 9, 29), #(11, 0, 0)),
    ),
  ])
}

pub fn increment_attempts_test() {
  let conn = new_db()
  let job_store = postgres_db_adapter.new(conn, [fn(_) { Nil }])

  let assert Ok(job) =
    job_store.enqueue_job(
      job_name,
      job_payload,
      birl.now() |> birl.to_erlang_datetime(),
    )

  job_store.increment_attempts(job)
  |> should.be_ok
  |> fn(j: jobs.Job) { j.attempts }
  |> should.equal(1)
}

pub fn migrate_test() {
  let conn = new_db()

  let assert Ok(_) = postgres_db_adapter.migrate_up(conn)()

  let sql =
    "
    SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
AND table_type = 'BASE TABLE';"

  pgo.execute(
    sql,
    conn,
    [],
    dynamic.decode1(fn(str) { str }, dynamic.element(0, dynamic.string)),
  )
  |> should.be_ok
  |> fn(result) {
    let pgo.Returned(count, rows) = result
    #(count, list.sort(rows, by: string.compare))
  }
  |> should.equal(#(3, ["jobs", "jobs_failed", "jobs_succeeded"]))

  let assert Ok(_) = postgres_db_adapter.migrate_down(conn)()
  pgo.execute(
    sql,
    conn,
    [],
    dynamic.decode1(fn(str) { str }, dynamic.element(0, dynamic.string)),
  )
  |> should.be_ok
  |> should.equal(pgo.Returned(0, []))
}

pub fn empty_list_of_jobs_test() {
  let conn = new_db()
  let job_store = postgres_db_adapter.new(conn, [fn(_) { Nil }])

  job_store.claim_jobs(["job_name"], 3, "default_queue")
  |> should.be_ok
}

pub fn multiple_list_of_jobs_test() {
  let conn = new_db()
  let job_store = postgres_db_adapter.new(conn, [fn(_) { Nil }])

  let assert Ok(_) =
    job_store.enqueue_job(
      job_name,
      job_payload,
      birl.now() |> birl.to_erlang_universal_datetime(),
    )
  let assert Ok(_) =
    job_store.enqueue_job(
      job_name,
      job_payload,
      birl.now() |> birl.to_erlang_universal_datetime(),
    )
  let assert Ok(_) =
    job_store.enqueue_job(
      job_name,
      job_payload,
      birl.now() |> birl.to_erlang_universal_datetime(),
    )
  let assert Ok(_) =
    job_store.enqueue_job(
      job_name,
      job_payload,
      birl.now() |> birl.to_erlang_universal_datetime(),
    )

  job_store.claim_jobs(["job_name"], 3, "default_queue")
  |> should.be_ok
}

pub fn db_events_test() {
  let event_logger = test_helpers.new_logger()
  let conn = new_db()
  let job_store =
    postgres_db_adapter.new(conn, [
      test_helpers.new_logger_event_listner(event_logger, _),
    ])

  let assert Ok(_) =
    job_store.enqueue_job(
      "test_job_1",
      "test_payaload_1",
      birl.now() |> birl.to_erlang_universal_datetime(),
    )
  let assert Ok(_) =
    job_store.enqueue_job(
      "test_job_2",
      "test_payaload_2",
      birl.now() |> birl.to_erlang_universal_datetime(),
    )

  let job_1 =
    job_store.claim_jobs(["test_job_1"], 1, "default_queue")
    |> should.be_ok
    |> list.first
    |> should.be_ok

  let assert Ok(_) = job_store.increment_attempts(job_1)

  let assert Ok(_) = job_store.move_job_to_succeeded(job_1)
  let assert Ok(_) = job_store.get_succeeded_jobs(1)

  let job_2 =
    job_store.claim_jobs(["test_job_2"], 1, "default_queue")
    |> should.be_ok
    |> list.first
    |> should.be_ok

  let assert Ok(_) = job_store.move_job_to_failed(job_2, "test exception")
  let _ =
    job_store.get_failed_jobs(1)
    |> should.be_ok
    |> list.first
    |> should.be_ok

  // There is dynamic data that get's logged, so it's 
  // hard to check the exact output. Checking the number of 
  // lines logged should be enough for now.
  test_helpers.get_log(event_logger)
  |> list.length()
  |> should.equal(18)
}

pub fn release_claim_test() {
  let event_logger = test_helpers.new_logger()
  let conn = new_db()
  let job_store =
    postgres_db_adapter.new(conn, [
      test_helpers.new_logger_event_listner(event_logger, _),
    ])

  let assert Ok(_) =
    pgo.execute(
      "INSERT INTO jobs (id, name, payload, attempts, created_at, available_at, reserved_at, reserved_by)
      VALUES ($1, $2, $3, 0, '2023-01-01 00:00:00', '2023-01-01 00:00:00', '2023-01-01 00:00:00', $4)
      RETURNING *;",
      conn,
      [
        pgo.text("test_id"),
        pgo.text("test_job"),
        pgo.text("test"),
        pgo.text("default_queue"),
      ],
      utils.discard_decode,
    )
  job_store.release_claim("test_id")
  |> should.be_ok

  process.sleep(100)

  job_store.claim_jobs(["test_job"], 1, "default_queue")
  |> should.be_ok()
  |> list.first
  |> should.be_ok
}

pub fn scheduled_job_test() {
  let event_logger = test_helpers.new_logger()
  let conn = new_db()
  let job_store =
    postgres_db_adapter.new(conn, [
      test_helpers.new_logger_event_listner(event_logger, _),
    ])

  let assert Ok(_) =
    job_store.enqueue_job(
      "test_job",
      "test_payaload",
      birl.now()
        |> birl.add(duration.seconds(2))
        |> birl.to_erlang_datetime(),
    )

  process.sleep(200)

  job_store.claim_jobs(["test_job"], 1, "default_queue")
  |> should.be_ok
  |> should.equal([])

  // Wait for it to become available
  process.sleep(2000)

  job_store.claim_jobs(["test_job"], 1, "default_queue")
  |> should.be_ok
  |> list.map(fn(job) { job.name })
  |> should.equal(["test_job"])
}

pub fn get_running_jobs_test() {
  let conn = new_db()
  let job_store = postgres_db_adapter.new(conn, [])

  let assert Ok(_) =
    pgo.execute(
      "INSERT INTO jobs (
        id, 
        name, 
        payload, 
        attempts, 
        created_at, 
        available_at, 
        reserved_at,
        reserved_by
      )
      VALUES (
        'job_12345',                                 
        'process_order',                             
        '\"test-payload\"',       
        3,                                           
        '2024-09-29 10:30:00',                       
        '2024-09-29 10:30:00',                        
        '2024-09-29 11:00:00',                        
        'test_queue'
      ), (
        'job_6789',                                 
        'process_order',                             
        '\"test-payload\"',       
        3,                                           
        '2024-09-29 10:30:00',                       
        '2024-09-29 10:30:00',
        NULL,
        NULL
      );
    ",
      conn,
      [],
      utils.discard_decode,
    )

  job_store.get_running_jobs("test_queue")
  |> should.be_ok
  |> should.equal([
    jobs.Job(
      id: "job_12345",
      name: "process_order",
      payload: "\"test-payload\"",
      attempts: 3,
      created_at: #(#(2024, 09, 29), #(10, 30, 00)),
      available_at: #(#(2024, 09, 29), #(10, 30, 00)),
      reserved_at: option.Some(#(#(2024, 09, 29), #(11, 00, 00))),
      reserved_by: option.Some("test_queue"),
    ),
  ])
}

pub fn get_enqueued_jobs_test() {
  let conn = new_db()
  let job_store = postgres_db_adapter.new(conn, [])

  let assert Ok(_) =
    pgo.execute(
      "INSERT INTO jobs (
        id, 
        name, 
        payload, 
        attempts, 
        created_at, 
        available_at
      )
      VALUES (
        'job_12345',                                 
        'process_order',                             
        '\"test-payload\"',       
        3,                                           
        '2024-09-29 10:30:00',                       
        '2024-09-29 10:30:00'                       
      );
    ",
      conn,
      [],
      utils.discard_decode,
    )

  job_store.get_enqueued_jobs("process_order")
  |> should.be_ok
  |> should.equal([
    jobs.Job(
      id: "job_12345",
      name: "process_order",
      payload: "\"test-payload\"",
      attempts: 3,
      created_at: #(#(2024, 09, 29), #(10, 30, 00)),
      available_at: #(#(2024, 09, 29), #(10, 30, 00)),
      reserved_at: option.None,
      reserved_by: option.None,
    ),
  ])
}

// Helpers
fn validate_job(job: jobs.Job, job_name: String, job_payload: String) {
  job.name
  |> should.equal(job_name)

  job.payload
  |> should.equal(job_payload)

  should.equal(job.created_at, job.available_at)

  birl.compare(
    birl.now() |> birl.subtract(duration.seconds(1)),
    birl.from_erlang_universal_datetime(job.created_at),
  )
  |> should.equal(order.Lt)

  birl.compare(
    birl.now() |> birl.subtract(duration.seconds(1)),
    birl.from_erlang_universal_datetime(job.available_at),
  )
  |> should.equal(order.Lt)
}
