# frozen_string_literal: true
require "test_helper"

class JobsLifecycleTest < ActiveSupport::TestCase
  setup do
    @worker = SolidQueue::Worker.new(queues: "background", threads: 3, polling_interval: 0.5)
    @dispatcher = SolidQueue::Dispatcher.new(batch_size: 10, polling_interval: 1)
  end

  teardown do
    @worker.stop
    @dispatcher.stop

    JobBuffer.clear
  end

  test "enqueue and run jobs" do
    AddToBufferJob.perform_later "hey"
    AddToBufferJob.perform_later "ho"

    @dispatcher.start
    @worker.start

    wait_for_jobs_to_finish_for(2.seconds)

    assert_equal [ "hey", "ho" ], JobBuffer.values.sort
    assert_equal 2, SolidQueue::Job.finished.count
  end

  test "schedule and run jobs" do
    AddToBufferJob.set(wait: 1.day).perform_later("I'm scheduled")
    AddToBufferJob.set(wait: 3.days).perform_later("I'm scheduled later")

    @dispatcher.start
    @worker.start

    assert_equal 2, SolidQueue::ScheduledExecution.count

    travel_to 2.days.from_now

    wait_for_jobs_to_finish_for(2.seconds)

    assert_equal 1, JobBuffer.size
    assert_equal "I'm scheduled", JobBuffer.last_value

    travel_to 5.days.from_now

    wait_for_jobs_to_finish_for(2.seconds)

    assert_equal 2, JobBuffer.size
    assert_equal "I'm scheduled later", JobBuffer.last_value

    assert_equal 2, SolidQueue::Job.finished.count
  end

  test "delete finished jobs after they run" do
    deleting_finished_jobs do
      AddToBufferJob.perform_later "hey"
      @worker.start

      wait_for_jobs_to_finish_for(2.seconds)
    end

    assert_equal 0, SolidQueue::Job.count
  end

  test "clear finished jobs after configured period" do
    10.times { AddToBufferJob.perform_later(2) }
    jobs = SolidQueue::Job.last(10)

    assert_no_difference -> { SolidQueue::Job.count } do
      SolidQueue::Job.clear_finished_in_batches
    end

    # Simulate that only 5 of these jobs finished
    jobs.sample(5).each(&:finished!)

    assert_no_difference -> { SolidQueue::Job.count } do
      SolidQueue::Job.clear_finished_in_batches
    end

    travel_to 3.days.from_now

    assert_difference -> { SolidQueue::Job.count }, -5 do
      SolidQueue::Job.clear_finished_in_batches
    end
  end

  private
    def deleting_finished_jobs
      previous, SolidQueue.preserve_finished_jobs = SolidQueue.preserve_finished_jobs, false
      yield
    ensure
      SolidQueue.preserve_finished_jobs = previous
    end
end
