class HardWorker
  include Sidekiq::Worker

  def perform(*args)
    # Do something
    Rails.logger.info "It works!"
  end
end
