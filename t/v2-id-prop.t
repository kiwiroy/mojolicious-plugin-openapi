use Mojo::Base -strict;
use Test::Mojo;
use Test::More;

use Mojo::File qw(curfile);
use Mojolicious::Lite;
my $id = 'foo';
get '/user' => sub {
  my $c = shift->openapi->valid_input or return;
  $c->render(openapi => {email => 'jhthorsen@cpan.org', id => $id});
  },
  'getUser';

plugin OpenAPI => {url => join '', "file://", curfile->sibling(qw(spec v2-id-spec.json))};

my $t = Test::Mojo->new;

$t->get_ok('/api/user')->status_is(500)
  ->json_is('/errors/0', {message => 'Expected integer - got string.', path => '/id'});

$id = 42;
$t->get_ok('/api/user')->status_is(200)->json_is('/email', 'jhthorsen@cpan.org')
  ->json_is('/id', 42);

done_testing;

__DATA__
@@ schema.json
{
  "swagger": "2.0",
  "info": { "version": "0.8", "title": "Test" },
  "basePath": "/api",
  "paths": {
    "/user": {
      "get": {
        "operationId": "getUser",
        "responses": {
          "200": {
            "description": "ok",
            "examples": {
              "application/json": {"id": "42"}
            },
            "schema": {
              "type": "object",
              "properties": {
                "email": {"type": "string"},
                "id": {"type": "integer"}
              }
            }
          }
        }
      }
    }
  }
}
