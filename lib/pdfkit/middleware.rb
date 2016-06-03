class PDFKit
  class Middleware
    def initialize(app, options = {}, conditions = {})
      @app        = app
      @options    = options
      @conditions = conditions
      @render_pdf = false
      @caching    = true
    end
    
    def call(env)
      @request    = Rack::Request.new(env)
      @render_pdf = false

      set_request_to_render_as_pdf(env) if render_as_pdf?
      status, headers, response = @app.call(env)

      if File.exists?(render_to) && rendering_pdf? && headers['Content-Type'] =~ /text\/html|application\/xhtml\+xml/
        file = File.open(render_to, "rb")
        body = file.read
        file.close
        response                  = [body]
        headers                   = { }
        headers["Content-Length"] = (body.respond_to?(:bytesize) ? body.bytesize : body.size).to_s
        headers["Content-Type"]   = "application/pdf"
        [200, headers, response]
      else
        if rendering_pdf? && headers['Content-Type'] =~ /text\/html|application\/xhtml\+xml/
          body = response.respond_to?(:body) ? response.body : response.join
          body = body.join if body.is_a?(Array)

          root_url = root_url(env)
          protocol = protocol(env)
          options = @options.merge(root_url: root_url, protocol: protocol)

          body = PDFKit.new(body, options).to_pdf
          response = [body]

          File.open(render_to, 'wb') { |file| file.write(body) } rescue nil

          unless @caching
            # Do not cache PDFs
            headers.delete('ETag')
            headers.delete('Cache-Control')
          end

          headers['Content-Length'] = (body.respond_to?(:bytesize) ? body.bytesize : body.size).to_s
          headers['Content-Type']   = 'application/pdf'
        end
      end
      [status, headers, response]
    end

    private


    def render_to
      file_name = Digest::MD5.hexdigest(@request.path) + ".pdf"
      file_path = "#{Rails.root}/tmp"
      "#{file_path}/#{file_name}"
    end

    def root_url(env)
      PDFKit.configuration.root_url || "#{env['rack.url_scheme']}://#{env['HTTP_HOST']}/"
    end

    def protocol(env)
      env['rack.url_scheme']
    end

    def rendering_pdf?
      @render_pdf
    end

    def render_as_pdf?
      request_path = @request.path
      return false unless request_path.end_with?('.pdf')

      if @conditions[:only]
        conditions_as_regexp(@conditions[:only]).any? do |pattern|
          pattern === request_path
        end
      elsif @conditions[:except]
        conditions_as_regexp(@conditions[:except]).none? do |pattern|
          pattern === request_path
        end
      else
        true
      end
    end

    def flock(file, mode)
      success = file.flock(mode)
      if success
        begin
          yield file
        ensure
          file.flock(File::LOCK_UN)
        end
      end
      return success
    end

    def set_request_to_render_as_pdf(env)
      @render_pdf = true

      path = @request.path.sub(%r{\.pdf$}, '')
      path = path.sub(@request.script_name, '')

      %w[PATH_INFO REQUEST_URI].each { |e| env[e] = path }

      env['HTTP_ACCEPT'] = concat(env['HTTP_ACCEPT'], Rack::Mime.mime_type('.html'))
      env['Rack-Middleware-PDFKit'] = 'true'
    end

    def concat(accepts, type)
      (accepts || '').split(',').unshift(type).compact.join(',')
    end

    def conditions_as_regexp(conditions)
      Array(conditions).map do |pattern|
        pattern.is_a?(Regexp) ? pattern : Regexp.new("^#{pattern}")
      end
    end
  end
end
