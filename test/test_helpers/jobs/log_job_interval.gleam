import bg_jobs/internal/jobs
import bg_jobs/internal/worker
import gleam/erlang/process
import test_helpers

pub const job_name = "LOG_JOB_SCHEDULE"

pub fn worker(logger: process.Subject(test_helpers.LogMessage)) {
  worker.Worker(job_name: job_name, handler: handler(logger, _))
}

pub fn handler(logger: process.Subject(test_helpers.LogMessage), _job: jobs.Job) {
  test_helpers.log_message(logger)("test_log")
  Ok(Nil)
}
