# frozen_string_literal: true

module Turnstile
  module Loading
    # Class-level DSL mixed into controllers to configure
    # resource loading behaviour. All settings are stored in
    # a Loading::Config instance on the controller class.
    #
    # == Usage
    #
    #   class ArticlesController < ApplicationController
    #     include Turnstile::Controller
    #
    #     # Override the inferred model class:
    #     resource_class BlogPost
    #
    #     # Override the ID param:
    #     resource_id_param :slug
    #
    #     # Mark custom actions:
    #     load_singular :publish, :archive
    #     load_plural   :search
    #     skip_loading  :dashboard
    #
    #     # Fully custom loader for an action:
    #     load_resource :transfer do |controller|
    #       Article.find(controller.params[:article_id])
    #     end
    #   end
    #
    module Dsl
      def self.included(base)
        base.extend(ClassMethods)
      end

      # Class-level configuration methods.
      module ClassMethods
        # The config object; lazily initialized, inherited by
        # duplication so subclasses may override without
        # polluting the parent.
        def turnstile_config
          @turnstile_config ||= if superclass.respond_to?(
            :turnstile_config
          )
            superclass.turnstile_config.dup
          else
            Config.new
          end
        end

        # Set the model class explicitly.
        def resource_class(klass)
          turnstile_config.resource_class = klass
        end

        # Set the param key used to find a singular record.
        def resource_id_param(param_name)
          turnstile_config.id_param = param_name.to_sym
        end

        # Declare actions that load a singular record.
        def load_singular(*actions)
          actions.each do |a|
            turnstile_config.action_modes[a.to_sym] = :singular
          end
        end

        # Declare actions that load a collection.
        def load_plural(*actions)
          actions.each do |a|
            turnstile_config.action_modes[a.to_sym] = :plural
          end
        end

        # Declare actions that should not auto-load anything.
        def skip_loading(*actions)
          actions.each do |a|
            turnstile_config.action_modes[a.to_sym] = :skip
          end
        end

        # Register a fully custom loader block for an action.
        # The block receives the controller instance.
        def load_resource(action, &block)
          turnstile_config.custom_loaders[action.to_sym] = block
        end
      end
    end
  end
end
