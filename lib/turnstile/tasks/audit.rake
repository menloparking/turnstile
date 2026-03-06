# frozen_string_literal: true

namespace :turnstile do
  desc "Report authorization coverage for all " \
       "Turnstile controller actions"
  task audit: :environment do
    require "turnstile/audit"

    success = Turnstile::Audit.report
    exit(1) unless success
  end
end
