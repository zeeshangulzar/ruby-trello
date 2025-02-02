# frozen_string_literal: true

require 'oauth'
require 'json'
require 'logger'
require 'active_model'
require 'addressable/uri'
require 'active_support/core_ext/hash/indifferent_access'

# Ruby wrapper around the [Trello] API
#
# First, set up your key information. You can get this information by [clicking here][trello-app-key].
#
# You can get the key by going to this url in your browser:
# https://trello.com/1/authorize?key=TRELLO_CONSUMER_KEY_FROM_ABOVE&name=MyApp&response_type=token&scope=read,write,account&expiration=never
# Only request the permissions you need; i.e., scope=read if you only need read, or scope=write if you only need write. Comma separate scopes you need.
# If you want your token to expire after 30 days, drop the &expiration=never. Then run the following code, where KEY denotes the key returned from the
# url above:
#
# Trello.configure do |config|
#   config.consumer_key = TRELLO_CONSUMER_KEY
#   config.consumer_secret = TRELLO_CONSUMER_SECRET
#   config.oauth_token = TRELLO_OAUTH_TOKEN
#   config.oauth_token_secret = TRELLO_OAUTH_TOKEN_SECRET
# end
#
# All the calls this library make to Trello require authentication using these keys. Be sure to protect them.
#
# So lets say you want to get information about the user *bobtester*. We can do something like this:
#
#   bob = Member.find("bobtester")
#   # Print out his name
#   puts bob.full_name # "Bob Tester"
#   # Print his bio
#   puts bob.bio # A wonderfully delightful test user
#   # How about a list of his boards?
#   bob.boards
#
# And so much more. Consult the rest of the documentation for more information.
#
# Feel free to [peruse and participate in our Trello board][ruby-trello-board]. It's completely open to the public.
#
# [trello]: http://trello.com
# [trello-app-key]: https://trello.com/app-key
# [ruby-trello-board]: https://trello.com/board/ruby-trello/4f092b2ee23cb6fe6d1aaabd
module Trello
  autoload :Error,                'trello/error'
  autoload :Action,               'trello/action'
  autoload :Comment,              'trello/comment'
  autoload :Association,          'trello/association'
  autoload :AssociationProxy,     'trello/association_proxy'
  autoload :Attachment,           'trello/attachment'
  autoload :CoverImage,           'trello/cover_image'
  autoload :BasicData,            'trello/basic_data'
  autoload :Board,                'trello/board'
  autoload :Card,                 'trello/card'
  autoload :Checklist,            'trello/checklist'
  autoload :Client,               'trello/client'
  autoload :Configuration,        'trello/configuration'
  autoload :CustomField,          'trello/custom_field'
  autoload :CustomFieldItem,      'trello/custom_field_item'
  autoload :CustomFieldOption,    'trello/custom_field_option'
  autoload :HasActions,           'trello/has_actions'
  autoload :Item,                 'trello/item'
  autoload :CheckItemState,       'trello/item_state'
  autoload :Label,                'trello/label'
  autoload :LabelName,            'trello/label_name'
  autoload :List,                 'trello/list'
  autoload :Member,               'trello/member'
  autoload :MultiAssociation,     'trello/multi_association'
  autoload :Notification,         'trello/notification'
  autoload :Organization,         'trello/organization'
  autoload :PluginDatum,          'trello/plugin_datum'
  autoload :Request,              'trello/net'
  autoload :Response,             'trello/net'
  autoload :TInternet,            'trello/net'
  autoload :Token,                'trello/token'
  autoload :Webhook,              'trello/webhook'
  autoload :JsonUtils,            'trello/json_utils'
  autoload :AssociationInferTool, 'trello/association_infer_tool'
  autoload :Schema,               'trello/schema'

  module TFaraday
    autoload :TInternet,          'trello/net/faraday'
  end

  module TRestClient
    autoload :TInternet,          'trello/net/rest_client'
  end

  module Authorization
    autoload :AuthPolicy,         'trello/authorization'
    autoload :BasicAuthPolicy,    'trello/authorization'
    autoload :OAuthPolicy,        'trello/authorization'
  end

  module AssociationFetcher
    autoload :HasMany,            'trello/association_fetcher/has_many'
    autoload :HasOne,             'trello/association_fetcher/has_one'
  end

  module AssociationBuilder
    autoload :HasMany,            'trello/association_builder/has_many'
    autoload :HasOne,             'trello/association_builder/has_one'
  end

  # Version of the Trello API that we use by default.
  API_VERSION = 1

  # This specific error is thrown when your access token is invalid. You should get a new one.
  InvalidAccessToken = Class.new(Error)

  # This error is thrown when your client has not been configured
  ConfigurationError = Class.new(Error)

  def self.logger
    @logger ||= Logger.new(STDOUT)
  end

  def self.logger=(logger)
    @logger = logger
  end

  # The order in which we will try the http clients
  HTTP_CLIENT_PRIORITY = %w(rest-client faraday)
  HTTP_CLIENTS = {
    'faraday' => Trello::TFaraday::TInternet,
    'rest-client' => Trello::TRestClient::TInternet
  }

  def self.http_client
    @http_client ||= begin
      # No client has been set explicitly. Try to load each supported client.
      # The first one that loads successfully will be used.
      client = HTTP_CLIENT_PRIORITY.each do |key|
        begin
          require key
          break HTTP_CLIENTS[key]
        rescue LoadError
          next
        end
      end

      raise ConfigurationError, 'Trello requires either rest-client or faraday installed' unless client

      client
    end
  end

  def self.http_client=(http_client)
    if HTTP_CLIENTS.include?(http_client)
      begin
        require http_client
        @http_client = HTTP_CLIENTS[http_client]
      rescue LoadError
        raise ConfigurationError, "Trello tried to use #{http_client}, but that gem is not installed"
      end
    else
      raise ArgumentError, "Unsupported HTTP client: #{http_client}"
    end
  end

  def self.client
    @client ||= Client.new
  end

  def self.configure(&block)
    reset!
    client.configure(&block)
  end

  def self.reset!
    @client = nil
    @http_client = nil
  end

  def self.auth_policy; client.auth_policy; end
  def self.configuration; client.configuration; end

  # Url to Trello API public key page
  def self.public_key_url
    'https://trello.com/app-key'
  end

  # Url to token for making authorized requests to the Trello API
  #
  # @param options [Hash] Repository information to update
  # @option options [String] :name Name of the application
  # @option options [String] :key Application key
  # @option options [String] :response_type 'token'
  # @option options [String] :callback_method 'postMessage' or 'fragment'
  # @option options [String] :return_url URL the token should be returned to
  # @option options [String] :scope Comma-separated list of one or more of 'read', 'write', 'account'
  # @option options [String] :expiration '1hour', '1day', '30days', 'never'
  # @see https://developers.trello.com/authorize
  def self.authorize_url(options = {})
    params = options.dup
    params[:key] ||= configuration.developer_public_key or
      raise ArgumentError, 'Please configure your Trello public key'
    params[:name] ||= 'Ruby Trello'
    params[:scope] ||= 'read,write,account'
    params[:expiration] ||= 'never'
    params[:response_type] ||= 'token'
    uri = Addressable::URI.parse 'https://trello.com/1/authorize'
    uri.query_values = params
    uri
  end

  # Visit the Trello API public key page
  #
  # @see https://trello.com/app-key
  def self.open_public_key_url
    open_url public_key_url
  end

  # Visit the Trello authorized token page
  #
  # @see https://developers.trello.com/authorize
  def self.open_authorization_url(options = {})
    open_url authorize_url(options)
  end

  # @private
  def self.open_url(url)
    require 'launchy'
    Launchy.open(url.to_s)
  rescue LoadError
    warn 'Please install the launchy gem to open the url automatically.'
    url
  end
end
