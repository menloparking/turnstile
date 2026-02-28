# frozen_string_literal: true

class Page < ActiveRecord::Base
  scope :visible, -> { where(visible: true) }
end
