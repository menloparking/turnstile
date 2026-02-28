# frozen_string_literal: true

class User < ActiveRecord::Base
  def admin? = role == "admin"

  def editor? = role == "editor"

  def hr? = role == "hr"
end
