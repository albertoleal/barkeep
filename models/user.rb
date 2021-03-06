# A logged-in user can comment and have their view preferences saved.
#
# Fields:
#  - email
#  - username

require "lib/api"
require "digest/md5"

# A logged-in user, or the demo user.
# For demo users, we store their saved searches in their cookie instead of the database.
class User < Sequel::Model
  one_to_many :saved_searches, :order => [:user_order.desc]
  one_to_many :comments

  ONE_YEAR = 365

  # The Rack session (the cookie) for this current user. This cookie is only used to store saved searches
  # for demo users.
  def rack_session=(session)
    return unless demo?
    @session = session
    @session[:last_demo_saved_search_id] ||= 0
    # Use ONE_YEAR as the saved search time period for demo users, so they see many commits, even if
    # the Barkeep install hasn't had any new commits in awhile.
    @session[:saved_search_time_period] ||= User::ONE_YEAR
    if @session[:saved_searches].nil?
      # Have one default saved search for the demo account, so they can click around without searching.
      has_barkeep_repo = MetaRepo.instance.repos.find { |repo| repo.name == "barkeep" }
      @session[:saved_searches] = []
      @session[:saved_searches] << new_saved_search(:repos => "barkeep").values if has_barkeep_repo
    end
    nil
  end

  def validate
    super
    valid_saved_search_time_periods = [nil, 1, 3, 7, 14, 30, User::ONE_YEAR]
    unless valid_saved_search_time_periods.include?(saved_search_time_period)
      errors.add(:saved_search_time_period, "is invalid")
    end
  end

  # The saved_search_time_period is persisted in the cookie for demo users.
  def saved_search_time_period
    return @session[:saved_search_time_period] if demo? && @session
    values[:saved_search_time_period]
  end

  def saved_search_time_period=(value)
    return @session[:saved_search_time_period] = value if demo? && @session
    values[:saved_search_time_period] = value
  end

  # Assign the user an api key and secret on creation
  def before_create
    self.api_key = Api.generate_user_key
    self.api_secret = Api.generate_user_key
    super
  end

  def gravatar
    return "/assets/images/demo_avatar.png" if demo?
    hash = Digest::MD5.hexdigest(email.downcase)
    image_src = "http://www.gravatar.com/avatar/#{hash}"
  end

  def demo?() permission == "demo" end
  def admin?() permission == "admin" end

  def saved_searches
    if demo?
      searches = @session[:saved_searches].map { |options| create_cookie_backed_saved_search(options) }
      searches.sort_by!(&:user_order).reverse!
    else
      saved_searches_dataset.all
    end
  end

  def new_saved_search(options)
    options[:user_id] = id
    options[:user_order] ||= (saved_searches.map(&:user_order).max || -1) + 1
    if demo?
      options[:id] = @session[:last_demo_saved_search_id] += 1
      create_cookie_backed_saved_search(options)
    else
      SavedSearch.new(options)
    end
  end

  def find_saved_search(id)
    demo? ? saved_searches.find { |search| search.id == id } : saved_searches_dataset.first(:id => id)
  end

  def delete_saved_search(saved_search_id)
    if demo?
      @session[:saved_searches].delete_if { |saved_search| saved_search[:id] == saved_search_id.to_i }
    else
      SavedSearch.filter(:user_id => id, :id => saved_search_id).delete
    end
  end

  def create_cookie_backed_saved_search(options)
    session = @session
    before_save_method = proc do
      index = session[:saved_searches].index { |saved_search| saved_search[:id] == id }
      index ? session[:saved_searches][index] = values : session[:saved_searches] << self.values
      false # Returning false halts Sequel's save method chain.
    end
    # We're creating a SavedSearch instance with an "unrestricted primary key", because we're setting the id
    # column to an arbitrary int. Sequel normally doesn't allow you to set this since it's generated by the DB
    begin
      SavedSearch.unrestrict_primary_key
      search = SavedSearch.new(options)
    ensure
      SavedSearch.restrict_primary_key
    end
    search.define_singleton_method(:before_save, before_save_method)
    search
  end

end
