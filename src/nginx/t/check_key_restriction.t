# Copyright (C) Extensible Service Proxy Authors
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
################################################################################
#
use strict;
use warnings;
use JSON::PP;
use Data::Dumper;

################################################################################

use src::nginx::t::ApiManager;    # Must be first (sets up import path to
                                  # the Nginx test module)
use src::nginx::t::HttpServer;
use src::nginx::t::ServiceControl;
use Test::Nginx;    # Imports Nginx's test module
use Test::More;     # And the test framework

################################################################################

# Port assignments
my $NginxPort          = ApiManager::pick_port();
my $BackendPort        = ApiManager::pick_port();
my $ServiceControlPort = ApiManager::pick_port();

my $t = Test::Nginx->new()->has(qw/http proxy/)->plan(21);

# Save servce configuration that disables the report cache.
# Report request will be sent for each client request
$t->write_file('server.pb.txt', <<"EOF");
service_control_config {
  report_aggregator_config {
    cache_entries: 0
    flush_interval_ms: 1000
  }
}
EOF

# Save service name in the service configuration protocol buffer file.
$t->write_file( 'service.pb.txt',
  ApiManager::get_bookstore_service_config . <<"EOF");
control {
  environment: "http://127.0.0.1:${ServiceControlPort}"
}
EOF

ApiManager::write_file_expand( $t, 'nginx.conf', <<"EOF");
%%TEST_GLOBALS%%
daemon off;
events {
  worker_connections 32;
}
http {
  %%TEST_GLOBALS_HTTP%%
  server_tokens off;
  set_real_ip_from  0.0.0.0/1;
  set_real_ip_from  0::/1;
  real_ip_header    X-Forwarded-For;
  real_ip_recursive on;
  server {
    listen 127.0.0.1:${NginxPort};
    server_name localhost;
    location / {
      endpoints {
        api service.pb.txt;
        server_config server.pb.txt;
        %%TEST_CONFIG%%
        on;
      }
      proxy_pass http://127.0.0.1:${BackendPort};
    }
  }
}
EOF

$t->run_daemon( \&bookstore, $t, $BackendPort, 'bookstore.log' );
$t->run_daemon( \&servicecontrol, $t, $ServiceControlPort, 'servicecontrol.log' );
is( $t->waitforsocket("127.0.0.1:${BackendPort}"), 1, 'Bookstore socket ready.' );
is( $t->waitforsocket("127.0.0.1:${ServiceControlPort}"), 1,
  'Service control socket ready.' );
$t->run();

################################################################################

my $response = ApiManager::http($NginxPort,<<'EOF');
GET /shelves?key=this-is-an-api-key HTTP/1.0
Referer: http://google.com/bookstore/root
Host: localhost
X-Forwarded-For: 10.20.30.40
X-Android-Package: com.goolge.cloud.esp
X-Android-Cert: AIzaSyB4Gz8nyaSaWo63IPUcy5d_L8dpKtOTSD0
X-Ios-Bundle-Identifier: 5b40ad6af9a806305a0a56d7cb91b82a27c26909

EOF

$t->stop_daemons();

my ( $response_headers, $response_body ) = split /\r\n\r\n/, $response, 2;

like( $response_headers, qr/HTTP\/1\.1 200 OK/, 'Returned HTTP 200.' );
is( $response_body, <<'EOF', 'Shelves returned in the response body.' );
{ "shelves": [
    { "name": "shelves/1", "theme": "Fiction" },
    { "name": "shelves/2", "theme": "Fantasy" }
  ]
}
EOF

my @requests = ApiManager::read_http_stream( $t, 'bookstore.log' );
is( scalar @requests, 1, 'Backend received one request' );

my $r = shift @requests;

is( $r->{verb}, 'GET', 'Backend request was a get' );
is( $r->{uri}, '/shelves?key=this-is-an-api-key', 'Backend uri was /shelves' );
is( $r->{headers}->{host}, "127.0.0.1:${BackendPort}", 'Host header was set' );

@requests = ApiManager::read_http_stream( $t, 'servicecontrol.log' );
is( scalar @requests, 2, 'Service control received two requests' );

# check
$r = shift @requests;
is( $r->{verb}, 'POST', ':check verb was post' );
is( $r->{uri}, '/v1/services/endpoints-test.cloudendpointsapis.com:check',
  ':check was called');
is( $r->{headers}->{host}, "127.0.0.1:${ServiceControlPort}",
  'Host header was set');
is( $r->{headers}->{'content-type'}, 'application/x-protobuf',
  ':check Content-Type was protocol buffer');

my $check_request = decode_json(ServiceControl::convert_proto(
  $r->{body}, 'check_request', 'json' ) );

is( $check_request->{operation}->{labels}->
  {'servicecontrol.googleapis.com/caller_ip'}, "10.20.30.40",
  "servicecontrol.googleapis.com/caller_ip was overrode by ".
  "X-Forwarded-For header" );
is( $check_request->{operation}->{labels}->
  {'servicecontrol.googleapis.com/android_package_name'},
  "com.goolge.cloud.esp",
  "servicecontrol.googleapis.com/android_package_name ".
  "is 'com.goolge.cloud.esp'" );
is( $check_request->{operation}->{labels}->
  {'servicecontrol.googleapis.com/android_cert_fingerprint'},
  "AIzaSyB4Gz8nyaSaWo63IPUcy5d_L8dpKtOTSD0",
  "servicecontrol.googleapis.com/android_cert_fingerprint ".
  "is 'AIzaSyB4Gz8nyaSaWo63IPUcy5d_L8dpKtOTSD0'" );
is( $check_request->{operation}->{labels}->
  {'servicecontrol.googleapis.com/ios_bundle_id'},
  "5b40ad6af9a806305a0a56d7cb91b82a27c26909",
  "servicecontrol.googleapis.com/ios_bundle_id ".
  "is '5b40ad6af9a806305a0a56d7cb91b82a27c26909'" );

# report
$r = shift @requests;

is( $r->{verb}, 'POST', ':report verb was post' );
is( $r->{uri}, '/v1/services/endpoints-test.cloudendpointsapis.com:report',
  ':report was called');
is( $r->{headers}->{host}, "127.0.0.1:${ServiceControlPort}",
  'Host header was set');
is( $r->{headers}->{'content-type'}, 'application/x-protobuf',
  ':check Content-Type was protocol buffer' );

my $report_request = decode_json(ServiceControl::convert_proto(
  $r->{body}, 'report_request', 'json' ) );

################################################################################

sub bookstore {
  my ( $t, $port, $file ) = @_;
  my $server = HttpServer->new( $port, $t->testdir() . '/' . $file )
    or die "Can't create test server socket: $!\n";
  local $SIG{PIPE} = 'IGNORE';

  $server->on( 'GET', '/shelves?key=this-is-an-api-key', <<'EOF');
HTTP/1.1 200 OK
Connection: close

{ "shelves": [
    { "name": "shelves/1", "theme": "Fiction" },
    { "name": "shelves/2", "theme": "Fantasy" }
  ]
}
EOF
  $server->run();
}

sub servicecontrol {
  my ( $t, $port, $file ) = @_;
  my $server = HttpServer->new( $port, $t->testdir() . '/' . $file )
    or die "Can't create test server socket: $!\n";
  local $SIG{PIPE} = 'IGNORE';

  $server->on( 'POST',
    '/v1/services/endpoints-test.cloudendpointsapis.com:check', <<'EOF');
HTTP/1.1 200 OK
Connection: close

EOF

  $server->on( 'POST',
    '/v1/services/endpoints-test.cloudendpointsapis.com:report', <<'EOF');
HTTP/1.1 200 OK
Connection: close

EOF

  $server->run();
}

################################################################################