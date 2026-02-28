# frozen_string_literal: true

class ArticlesController < ApplicationController
  include Turnstile::Controller

  load_singular :publish
  load_plural :search
  skip_loading :create

  def index
    render plain: @articles.map(&:title).join(", ")
  end

  def show
    render plain: @article.title
  end

  def create
    article = Article.new(article_params)
    authorize(article, :create)
    article.save!
    render plain: "created", status: :created
  end

  def update
    render plain: "updated:#{@article.title}"
  end

  def destroy
    @article.destroy!
    render plain: "destroyed"
  end

  def publish
    @article.update!(published: true)
    render plain: "published"
  end

  def search
    render plain: @articles.map(&:title).join(", ")
  end

  private

  def article_params
    params.require(:article).permit(:title, :body)
  end
end
