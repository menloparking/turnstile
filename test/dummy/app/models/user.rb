# frozen_string_literal: true

class User < ActiveRecord::Base
  has_many :articles, foreign_key: :author_id

  def admin? = role == "admin"

  def editor? = role == "editor"

  def hr? = role == "hr"
end
