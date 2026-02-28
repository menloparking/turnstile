# frozen_string_literal: true

require_relative 'lib/turnstile/version'

Gem::Specification.new do |spec|
  spec.name = 'turnstile'
  spec.version = Turnstile::VERSION
  spec.authors = ['Gandalf']
  spec.summary = 'Resource loading and layered authorization for Rails'
  spec.description = <<~DESC
    Turnstile provides automatic resource loading and a three-tier
    authorization system (model, context, and view policies) for
    Rails controllers backed by ActiveRecord. Policies default to
    deny-all and expose rich reflection metadata for static analysis.
  DESC
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1'

  spec.files = Dir['lib/**/*', 'sig/**/*', 'LICENSE', 'README.md']
  spec.require_paths = ['lib']

  spec.add_dependency 'actionpack', '>= 7.0'
  spec.add_dependency 'activerecord', '>= 7.0'
  spec.add_dependency 'activesupport', '>= 7.0'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
