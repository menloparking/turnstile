# frozen_string_literal: true

class Article < ActiveRecord::Base
  belongs_to :author, class_name: "User", optional: true

  scope :published, -> { where(published: true) }
end
