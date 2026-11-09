class PagesController < ApplicationController
  def home
    HardWorker.perform_async
  end
end
