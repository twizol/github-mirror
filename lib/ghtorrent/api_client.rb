require 'open-uri'
require 'net/http'
require 'digest/sha1'
require 'fileutils'
require 'json'

require 'ghtorrent/logging'
require 'ghtorrent/settings'
require 'ghtorrent/time'
require 'ghtorrent/cache'

module GHTorrent
  module APIClient
    include GHTorrent::Logging
    include GHTorrent::Settings
    include GHTorrent::Cache

    # This is to fix an annoying bug in JRuby's SSL not being able to
    # verify a valid certificate.
    if defined? JRUBY_VERSION
      OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE
    end

    # A paged request. Used when the result can expand to more than one
    # result pages.
    def paged_api_request(url, pages = -1, cache = true)

      data = api_request_raw(url, use_cache?(cache, method = :paged))

      return [] if data.nil?

      unless data.meta['link'].nil?
        links = parse_links(data.meta['link'])

        if pages > 0
          pages = pages - 1
          if pages == 0
            return parse_request_result(data)
          end
        end

        if links['next'].nil?
          parse_request_result(data)
        else
          parse_request_result(data) |
              if links['next'] == links['last']
                paged_api_request(links['next'], pages, false)
              else
                paged_api_request(links['next'], pages, cache)
              end
        end
      else
        parse_request_result(data)
      end
    end

    # A normal request. Returns a hash or an array of hashes representing the
    # parsed JSON result.
    def api_request(url, cache = false)
      parse_request_result api_request_raw(url, use_cache?(cache))
    end

    private

    # Determine whether to use cache or not, depending on the type of the
    # request
    def use_cache?(client_request, method = :non_paged)
      @cache_mode ||= case config(:cache_mode)
                        when "dev"
                          :dev
                        when "prod"
                          :prod
                        else
                          raise GHTorrentException("")
                      end
      case @cache_mode
        when :dev
          unless client_request
            return false
          end
          return true
        when :prod
          if client_request
            return true
          else
            case method
              when :non_paged
                return false
              when :paged
                return true
            end
          end
      end
    end

    # Parse a Github link header
    def parse_links(links)
      links.split(/,/).reduce({}) do |acc, x|
        matches = x.strip.match(/<(.*)>; rel=\"(.*)\"/)
        acc[matches[2]] = matches[1]
        acc
      end
    end

    # Parse the JSON result array
    def parse_request_result(result)
      if result.nil?
        []
      else
        json = result.read

        if json.nil?
          []
        else
          JSON.parse(json)
        end
      end
    end

    # Do the actual request and return the result object
    def api_request_raw(url, use_cache = false)
      @num_api_calls ||= 0
      @ts ||= Time.now().tv_sec()

      #Rate limiting to avoid error requests
      if Time.now().tv_sec() - @ts < 60 then
        if @num_api_calls >= @settings['mirror']['reqrate'].to_i
          sleep = 60 - (Time.now().tv_sec() - @ts)
          debug "APIClient: Sleeping for #{sleep}"
          sleep (sleep)
          @num_api_calls = 0
          @ts = Time.now().tv_sec()
        end
      else
        debug "APIClient: Tick, num_calls = #{@num_api_calls}, zeroing"
        @num_api_calls = 0
        @ts = Time.now().tv_sec()
      end

      begin
        start_time = Time.now
        from_cache = false

        contents =
            if use_cache
              if not (cached = cache_get(url)).nil?
                from_cache = true
                cached
              else
                tocache = Cachable.new(do_request(url))
                @num_api_calls += 1
                cache_put(url, tocache)
                tocache
              end
            else
              @num_api_calls += 1
              do_request(url)
            end

        total = Time.now.to_ms - start_time.to_ms
        debug "APIClient: Request: #{url} (#{@num_api_calls} calls,#{if from_cache then " from cache," end} Total: #{total} ms)"
        contents
      rescue OpenURI::HTTPError => e
        case e.io.status[0].to_i
          # The following indicate valid Github return codes
          when 400, # Bad request
              401, # Unauthorized
              403, # Forbidden
              404, # Not found
              422 then # Unprocessable entity
            STDERR.puts "#{url}: #{e.io.status[1]}"
            return nil
          else # Server error or HTTP conditions that Github does not report
            STDERR.puts "#{url}"
            raise e
        end
      end
    end

    def do_request(url)
      @attach_ip ||= config(:attach_ip)

      if @attach_ip.nil? or @attach_ip.eql? "0.0.0.0"
        open(url)
      else
        attach_to(@attach_ip) do
          open(url)
        end
      end
    end

    # Attach to a specific IP address if the machine has multiple
    def attach_to(ip)
      TCPSocket.instance_eval do
        (class << self; self; end).instance_eval do
          alias_method :original_open, :open

          define_method(:open) do |conn_address, conn_port|
            original_open(conn_address, conn_port, ip)
          end
        end
      end

      result = begin
        yield
      rescue Exception => e
        raise e
      ensure
        TCPSocket.instance_eval do
          (class << self; self; end).instance_eval do
            alias_method :open, :original_open
            remove_method :original_open
          end
        end
      end

      result
    end

  end
end

class Cachable

  include OpenURI::Meta

  attr_reader :base_uri, :meta, :status

  def initialize(response)
    @data = response.read
    @base_uri = response.base_uri
    @meta = response.meta
    @status = response.status
  end

  def read
    @data
  end

end
