# frozen_string_literal: true

Rails.application.routes.draw do
  resources :articles do
    member do
      post :publish
    end
    collection do
      get :search
    end
  end

  resources :pages, only: %i[index show]

  get "health", to: "health#check"
end
