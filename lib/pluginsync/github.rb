require 'netrc'
require 'octokit'

module Pluginsync
  module Github
    INTEL_ORG = Pluginsync.config.org

    Octokit.auto_paginate = true

    begin
      require 'faraday-http-cache'
      stack = Faraday::RackBuilder.new do |builder|
        builder.use Faraday::HttpCache, :serializer => Marshal
        builder.use Octokit::Response::RaiseError
        builder.adapter Faraday.default_adapter
      end
      Octokit.middleware = stack
    rescue LoadError
    end

    def self.client
      raise(Exception, "missing $HOME/.netrc configuration") unless File.exists? File.join(ENV["HOME"], ".netrc")
      @@client ||= Octokit::Client.new(:netrc => true)
    end

    def self.issues name
      client.issues name
    end

    def self.repo name
      client.repo name
    end

    class Repo
      @log = Pluginsync.log

      attr_reader :name

      def initialize(name, supported=false)
        @name = name
        @supported = supported
        @gh = Pluginsync::Github.client
        raise(ArgumentError, "#{name} is not a valid github repository (or your account does not have access to this private repo)") unless @gh.repository? name
        @repo = @gh.repo name
        @owner = @repo.owner.login
      end

      def content(path, default=nil)
        file = @gh.contents(@name, :path=>path)
        Base64.decode64 file.content
      rescue
        nil
      end

      def upstream
        if @repo.fork?
          @repo.parent.full_name
        else
          nil
        end
      end

      def ref_sha(ref, repo=@name)
        refs = @gh.refs repo
        if result = refs.find{ |r| r.ref == ref }
          result.object.sha
        else
          nil
        end
      end

      def sync_branch(branch, opt={})
        parent = opt[:origin] || upstream || raise(ArgumentError, "Repo #{@name} is not a fork and no origin specified for syncing.")
        origin_branch = opt[:branch] || 'master'

        origin_sha = ref_sha("refs/heads/#{origin_branch}", parent)

        fork_ref = "heads/#{branch}"
        fork_sha = ref_sha("refs/heads/#{branch}")

        if ! fork_sha
          @gh.create_ref(@name, fork_ref, origin_sha)
        elsif origin_sha != fork_sha
          begin
            @gh.update_ref(@name, fork_ref, origin_sha)
          rescue Octokit::UnprocessableEntity
            @log.warn "Fork #{name} is out of sync with #{parent}, syncing to #{name} #{origin_branch}"
            origin_sha = ref_sha("refs/heads/#{origin_branch}")
            @gh.update_ref(@name, fork_ref, origin_sha)
          end
        end
      end

      def update_content(path, content, opt={})
        branch = opt[:branch] || "master"

        raise(ArgumentError, "This tool cannot directly commit to #{INTEL_ORG} repos") if @name =~ /^#{INTEL_ORG}/
        raise(ArgumentError, "This tool cannot directly commit to master branch") if branch == 'master'

        message = "update #{path} by pluginsync tool"
        content = Base64.encode64 content

        ref = "heads/#{branch}"
        latest_commit = @gh.ref(@name, ref).object.sha
        base_tree = @gh.commit(@name, latest_commit).commit.tree.sha

        sha = @gh.create_blob(@name, content, "base64")
        new_tree = @gh.create_tree(
          @name,
          [ {
            :path => path,
            :mode => "100644",
            :type => "blob",
            :sha => sha
          } ],
          { :base_tree => base_tree }
        ).sha

        new_commit = @gh.create_commit(@name, message, new_tree, latest_commit).sha
        @gh.update_ref(@name, ref, new_commit) if branch
      end

      def create_pull_request(source="master", branch, message)
        @gh.create_pull_request(upstream, source, "#{@repo.owner.login}:#{branch}", message)
      end

      def yml_content(path, default={})
        YAML.load(content(path))
      rescue
        default
      end

      def plugin_name
        @name.match(/snap-plugin-(collector|processor|publisher)-(.*)$/)
        @plugin_name = Pluginsync::Util.plugin_capitalize($2) || raise(ArgumentError, "Unable to parse plugin name from repo: #{@name}")
      end

      def plugin_type
        @plugin_type ||= case @name
          when /collector/
            "collector"
          when /processor/
            "processor"
          when /publisher/
            "publisher"
          else
            "unknown"
          end
      end

      def sync_yml
        @sync_yml ||= fetch_sync_yml.extend Hashie::Extensions::DeepFetch
      end

      ##
      # For intelsdi-x plugins merge pluginsync config_defaults with repo .sync.yml
      #
      def fetch_sync_yml
        if @owner == Pluginsync::Github::INTEL_ORG
          path = File.join(Pluginsync::PROJECT_PATH, 'config_defaults.yml')
          config = Pluginsync::Util.load_yaml(path)
          config.extend Hashie::Extensions::DeepMerge
          config.deep_merge(yml_content('.sync.yml'))
        else
          {}
        end
      end

      def metric
        total = 0
        metric = Hash.new{ |h, k| h[k]={} }

        # NOTE: passing beta media type to avoid the following message:
        # WARNING: The preview version of the Traffic API is not yet suitable for production use.
        # You can avoid this message by supplying an appropriate media type in the 'Accept' request
        # header.
        clones = @gh.clones(@name, per: 'week', accept: 'application/vnd.github.beta+json')
        metric['clones']['count'] = clones.count
        metric['clones']['uniques'] = clones.uniques

        views = @gh.views(@name, per: 'week', accept: 'application/vnd.github.beta+json')
        metric['views']['count'] = views.count
        metric['views']['uniques'] = views.uniques

        @gh.releases(@name).each do |r|
          assets = Hash.new
          r.assets.each do |a|
            total += a.download_count
            assets[a.name] = a.download_count
          end
          metric[r.tag_name] = assets
        end
        metric['total'] = total

        { @name => metric }
      rescue Octokit::Forbidden
        puts "Require admin access to #{name} for repo metrics."
        { @name => nil }
      end

      def owner
        @owner ||= @repo.owner.login
      end

      def metadata
        result = {
          "name" => plugin_name,
          "type" =>  plugin_type,
          "supported" => @supported,
          "description" => @repo.description || 'No description available.',
          "maintainer" => @owner,
          "maintainer_url" => @repo.owner.html_url,
          "repo_name" => @repo.name,
          "repo_url" => @repo.html_url,
        }

        metadata = yml_content('metadata.yml')

        if (@owner == Pluginsync::Github::INTEL_ORG) and (plugin_name != 'Mesos')
          metadata["badge"] ||= "[![Build Status](https://travis-ci.org/intelsdi-x/#{@repo.name}.svg?branch=master)](https://travis-ci.org/intelsdi-x/#{@repo.name})"
        end

        metadata["name"] = Pluginsync::Util.plugin_capitalize metadata["name"] if metadata["name"]
        if @gh.releases(@name).size > 0
          metadata["github_release"] = @repo.html_url + "/releases"
          metadata["downloads"] = ["[release](#{metadata['github_release']})"]
        end
        metadata["maintainer"] = "intelsdi-x" if metadata["maintainer"] == "core"

        result.merge(metadata)
      end

      def s3_url(build)
        matrix = sync_yml.deep_fetch :global, "build", "matrix"
        matrix.collect do |go|
          arch = if go["GOARCH"] == "amd64"
                   "x86_64"
                 else
                   go["GOARCH"]
                 end
          { "#{go['GOOS']}/#{arch}" => "https://s3-us-west-2.amazonaws.com/snap.ci.snap-telemetry.io/plugins/#{@repo.name}/#{build}/#{go['GOOS']}/#{arch}/#{@repo.name}" }
        end
      end
    end
  end
end
