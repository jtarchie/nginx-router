#!/usr/bin/env ruby

require 'digest/md5'
require 'erb'
require 'json'
require 'uri'

def config
  @config ||= JSON.parse(File.read('/var/vcap/jobs/router/config/router.json'))
end

HTTPRoute = Struct.new(:uri, :results) do
  def upstream_name
    @upstream_name ||= "upstream_#{Digest::MD5.hexdigest uri}"
  end

  def upstreams
    @upstream ||= begin
                    results.map do |result|
                      "#{result['ip']}:#{result['port']}"
                    end
                  end
  end

  def path
    @path ||= URI.parse(uri).path
  end
end

def http_routes
  output = `rtr list \
    --api #{config.dig('routing_api', 'uri')}:#{config.dig('routing_api', 'port')} \
    --client-id gorouter \
    --client-secret #{config.dig('uaa', 'clients', 'gorouter', 'secret')} \
    --oauth-url #{config.dig('uaa', 'token_endpoint')}:#{config.dig('uaa','ssl','port')}`.chomp

  results = JSON.parse(output.split("\n").last)
  results_by_route = results.group_by { |r| r['route'] }
  results_by_route.map do |uri, results|
    HTTPRoute.new("http://#{uri}", results)
  end
end

upstreams_template = ERB.new(<<-EOF)
<% http_routes.each do |route| %>
upstream <%= route.upstream_name %> {
  <% route.upstreams.each do |upstream| %>
  server <%= upstream.to_s %>;
  <% end %>
}
<% end %>
EOF

locations_template = ERB.new(<<-EOF)
<% http_routes.each do |route| %>
location <%= route.path %> {
  proxy_pass http://<%= route.upstream_name %>;
}
<% end %>
EOF

loop do
  File.write(
    '/var/vcap/run/nginx/ext/upstreams.conf',
    upstreams_template.result(binding)
  )
  File.write(
    '/var/vcap/run/nginx/ext/locations.conf',
    locations_template.result(binding)
  )
  system('kill -s HUP $(cat /var/vcap/run/nginx/nginx.pid)')
  sleep 10
end
