#!/usr/bin/env ruby

require 'digest/md5'
require 'erb'
require 'json'
require 'nats/io/client'
require 'uri'

Endpoint = Struct.new(:host, :port, :uri)
HTTPRoute = Struct.new(:uri, :results) do
  def upstream_name
    @upstream_name ||= "upstream_#{Digest::MD5.hexdigest uri}"
  end

  def upstreams
    @upstream ||= begin
                    results.map do |result|
                      "#{result.host}:#{result.port}"
                    end
                  end
  end

  def path
    @path ||= URI.parse(uri).path
  end
end

def config
  @config ||= JSON.parse(File.read('/var/vcap/jobs/router/config/router.json'))
end

def nats_client
  @nats_client ||= begin
                     nats = NATS::IO::Client.new
                     nats.connect(
                       servers: config.dig('nats', 'machines').map do |ip|
                         "#{config.dig('nats', 'user')}:#{config.dif('nats', 'password')}@#{ip}:#{config.dig('nats', 'port')}"
                       end,
                       reconnect_time_wait: 0.5,
                       max_reconnect_attempts: 2
                     )
                   end
end

def endpoints
  @endpoints ||= Set.new
end

def endpoints_from_payload(reply)
  payload = JSON.parse(reply)
  payload['uris'].maps do |uri|
    Endpoint.new(
      payload['host'],
      payload['port'],
      uri
    )
  end
end

def main
  File.write(
    '/var/vcap/run/nginx/ext/upstreams.conf',
    upstreams_template.result(binding)
  )
  File.write(
    '/var/vcap/run/nginx/ext/locations.conf',
    locations_template.result(binding)
  )
  system('kill -s HUP $(cat /var/vcap/run/nginx/nginx.pid)')
end

def http_routes
  # output = `rtr list \
  #   --api #{config.dig('routing_api', 'uri')}:#{config.dig('routing_api', 'port')} \
  #   --client-id gorouter \
  #   --client-secret #{config.dig('uaa', 'clients', 'gorouter', 'secret')} \
  #   --oauth-url #{config.dig('uaa', 'token_endpoint')}:#{config.dig('uaa','ssl','port')}`.chomp

  # results = JSON.parse(output.split("\n").last)
  # results_by_route = results.group_by { |r| r['route'] }
  # results_by_route.map do |uri, results|
  #   HTTPRoute.new("http://#{uri}", results)
  # end
  results_by_route = endpoints.group_by { |e| e.uri }
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

def start_message
  nats_client.publish('router.start', {
    id: config.dig('spec', 'id'),
    hosts: [ config.dig('spec', 'address') ],
    minimumRegisterIntervalInSeconds: 20,
    prunteThresholdInSeconds: 120,
  }.to_json)
end

nats_client.subscribe('router.greet') do
  start_message
end

nats_client.subscribe('router.*') do |msg, reply, subject|
  case msg
  when 'router.register'
    endpoints.add(endpoints_from_payload(reply))
  when 'router.unregister'
    endpoints.delete(endpoints_from_payload(reply))
  end
end

start_message
if __FILE__ == $0
  loop do
    main
    sleep 10
  end
end

loop do
  sleep 10
end
