require 'uri'
require 'openid'
require 'rack/openid'

module OpenIdAuthentication
  
  module ControllerMethods
    protected
      # The parameter name of "openid_identifier" is used rather than
      # the Rails convention "open_id_identifier" because that's what
      # the specification dictates in order to get browser auto-complete
      # working across sites
      def using_open_id?(identifier = nil) #:doc:
        identifier ||= open_id_identifier
        !identifier.blank? || request.env[Rack::OpenID::RESPONSE]
      end

      def authenticate_with_open_id(identifier = nil, options = {}, &block) #:doc:
        identifier ||= open_id_identifier

        if request.env[Rack::OpenID::RESPONSE]
          complete_open_id_authentication(&block)
        else
          begin_open_id_authentication(identifier, options, &block)
        end
      end

    private
      def open_id_identifier
        params[:openid_identifier] || params[:openid_url]
      end

      def begin_open_id_authentication(identifier, options = {})
        options[:identifier] = identifier
        value = Rack::OpenID.build_header(options)
        response.headers[Rack::OpenID::AUTHENTICATE_HEADER] = value
        head :unauthorized
      end

      def complete_open_id_authentication
        response   = request.env[Rack::OpenID::RESPONSE]
        identifier = response.display_identifier

        case response.status
        when OpenID::Consumer::SUCCESS
          yield Result[:successful], identifier,
            OpenID::SReg::Response.from_success_response(response),
            OpenID::AX::FetchResponse.from_success_response(response)
        when :missing
          yield Result[:missing], identifier, nil
        when :invalid
          yield Result[:invalid], identifier, nil
        when OpenID::Consumer::CANCEL
          yield Result[:canceled], identifier, nil
        when OpenID::Consumer::FAILURE
          yield Result[:failed], identifier, nil
        when OpenID::Consumer::SETUP_NEEDED
          yield Result[:setup_needed], response.setup_url, nil
        end
      end
  end
  
  def self.new(app)
    store = OpenIdAuthentication.store
    if store.nil?
      Rails.logger.warn "OpenIdAuthentication.store is nil. Using in-memory store."
    end

    ::Rack::OpenID.new(app, OpenIdAuthentication.store)
  end

  def self.store
    @@store
  end

  def self.store=(*store_option)
    store, *parameters = *([ store_option ].flatten)

    @@store = case store
    when :memory
      require 'openid/store/memory'
      OpenID::Store::Memory.new
    when :file
      require 'openid/store/filesystem'
      OpenID::Store::Filesystem.new(Rails.root.join('tmp/openids'))
    when :memcache
      require 'memcache'
      require 'openid/store/memcache'
      OpenID::Store::Memcache.new(MemCache.new(parameters))
    else
      store
    end
  end

  self.store = nil

  if Rails.version >= '3'
    class Railtie < ::Rails::Railtie
      config.app_middleware.use OpenIdAuthentication

      config.after_initialize do
        OpenID::Util.logger = Rails.logger
      end

      ActiveSupport.on_load :action_controller do
        ActionController::Base.send :include, ::OpenIdAuthentication::ControllerMethods
      end
    end
  end

  class Result
    ERROR_MESSAGES = {
      :missing      => "Sorry, the OpenID server couldn't be found",
      :invalid      => "Sorry, but this does not appear to be a valid OpenID",
      :canceled     => "OpenID verification was canceled",
      :failed       => "OpenID verification failed",
      :setup_needed => "OpenID verification needs setup"
    }

    def self.[](code)
      new(code)
    end

    def initialize(code)
      @code = code
    end

    def status
      @code
    end

    ERROR_MESSAGES.keys.each { |state| define_method("#{state}?") { @code == state } }

    def successful?
      @code == :successful
    end

    def unsuccessful?
      ERROR_MESSAGES.keys.include?(@code)
    end

    def message
      ERROR_MESSAGES[@code]
    end
  end

end
