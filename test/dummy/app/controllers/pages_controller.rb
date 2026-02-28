# frozen_string_literal: true

class PagesController < ApplicationController
  include Turnstile::Controller

  def index
    render plain: @pages.map(&:title).join(", ")
  end

  def show
    render plain: @page.title
  end
end
