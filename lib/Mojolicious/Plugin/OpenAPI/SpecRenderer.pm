package Mojolicious::Plugin::OpenAPI::SpecRenderer;
use Mojo::Base 'Mojolicious::Plugin';

use JSON::Validator;
use Mojo::JSON;

use constant DEBUG    => $ENV{MOJO_OPENAPI_DEBUG} || 0;
use constant MARKDOWN => eval 'require Text::Markdown;1';

sub register {
  my ($self, $app, $config) = @_;

  $self->{standalone} = $config->{openapi} ? 0 : 1;
  $app->helper('openapi.render_spec' => sub { $self->_render_spec(@_) });

  unless ($app->{'openapi.render_specification'}++) {
    push @{$app->renderer->classes}, __PACKAGE__;
    push @{$app->static->classes},   __PACKAGE__;
  }
  $self->_register_with_openapi($app, $config) unless $self->{standalone};
}

sub _register_with_openapi {
  my ($self, $app, $config) = @_;
  my $openapi = $config->{openapi};

  if ($config->{render_specification} // 1) {
    my $spec_route = $openapi->route->get('/')->to(cb => sub { shift->openapi->render_spec(@_) });
    my $name       = $config->{spec_route_name} || $openapi->validator->get('/x-mojo-name');
    $spec_route->name($name) if $name;
  }

  if ($config->{render_specification_for_paths} // 1) {
    $app->plugins->once(openapi_routes_added => sub { $self->_add_documentation_routes(@_) });
  }
}

sub _add_documentation_routes {
  my ($self, $openapi, $routes) = @_;
  my %dups;

  for my $route (@$routes) {
    my $route_path = $route->to_string;
    next if $dups{$route_path}++;

    my $openapi_path = $route->to->{'openapi.path'};
    my $doc_route
      = $openapi->route->options($route->pattern->unparsed, {'openapi.default_options' => 1});
    $doc_route->to(cb => sub { $self->_render_spec(shift, $openapi_path) });
    $doc_route->name(join '_', $route->name, 'openapi_documentation')              if $route->name;
    warn "[OpenAPI] Add route options $route_path (@{[$doc_route->name // '']})\n" if DEBUG;
  }
}

sub _markdown {
  return Mojo::ByteStream->new(MARKDOWN ? Text::Markdown::markdown($_[0]) : $_[0]);
}

sub _render_partial_spec {
  my ($self, $c, $path) = @_;
  my $validator = $self->_validator($c);
  my $method    = $c->param('method');

  my $bundled = $validator->get([paths => $path]);
  $bundled = $validator->bundle({schema => $bundled}) if $bundled;
  my $definitions = $bundled->{definitions} || {} if $bundled;
  my $parameters  = $bundled->{parameters}  || [];

  if ($method and $bundled = $bundled->{$method}) {
    push @$parameters, @{$bundled->{parameters} || []};
  }

  return $c->render(json => {errors => [{message => 'No spec defined.'}]}, status => 404)
    unless $bundled;

  delete $bundled->{$_} for qw(definitions parameters);
  return $c->render(
    json => {
      '$schema'   => 'http://json-schema.org/draft-04/schema#',
      title       => $validator->get([qw(info title)]) || '',
      description => $validator->get([qw(info description)]) || '',
      definitions => $definitions,
      parameters  => $parameters,
      %$bundled,
    }
  );
}

sub _render_spec {
  my ($self, $c, $path) = @_;
  return $self->_render_partial_spec($c, $path) if $path;

  my $openapi = $self->{standalone} ? undef : Mojolicious::Plugin::OpenAPI::_self($c);
  my $format  = $c->stash('format') || 'json';
  my %spec;

  if ($openapi) {
    $openapi->{bundled} ||= $openapi->validator->bundle;
    %spec = %{$openapi->{bundled}};

    if ($openapi->validator->version ge '3') {
      $spec{servers} = [{url => $c->req->url->to_abs->to_string}];
      delete $spec{basePath};    # Added by Plugin::OpenAPI
    }
    else {
      $spec{basePath} = $c->url_for($spec{basePath});
      $spec{host}     = $c->req->url->to_abs->host_port;
    }
  }
  elsif ($c->stash('openapi_spec')) {
    %spec = %{$c->stash('openapi_spec') || {}};
  }

  return $c->render(json => {errors => [{message => 'No specification to render.'}]}, status => 500)
    unless %spec;

  return $c->render(json => \%spec) unless $format eq 'html';
  return $c->render(
    handler   => 'ep',
    template  => 'mojolicious/plugin/openapi/layout',
    esc       => sub { local $_ = shift; s/\W/-/g; $_ },
    markdown  => \&_markdown,
    serialize => \&_serialize,
    spec      => \%spec,
    X_RE      => qr{^x-},
  );
}

sub _validator {
  my ($self, $c) = @_;
  return Mojolicious::Plugin::OpenAPI::_self($c)->validator unless $self->{standalone};
  return JSON::Validator->new->schema($c->stash('openapi_spec'));
}

sub _serialize { Mojo::JSON::encode_json(@_) }

1;

=encoding utf8

=head1 NAME

Mojolicious::Plugin::OpenAPI::SpecRenderer - Render OpenAPI specification

=head1 SYNOPSIS

=head2 With Mojolicious::Plugin::OpenAPI

  $app->plugin(OpenAPI => {
    plugins                        => [qw(+SpecRenderer)],
    render_specification           => 1,
    render_specification_for_paths => 1,
    %openapi_parameters,
  });

See L<Mojolicious::Plugin::OpenAPI/register> for what
C<%openapi_parameters> might contain.

=head2 Standalone

  use Mojolicious::Lite;
  plugin "Mojolicious::Plugin::OpenAPI::SpecRenderer";

  # Some specification to render
  my $petstore = app->home->child("petstore.json");

  get "/my-spec" => sub {
    my $c = shift;

    # "openapi_spec" can also be set in...
    # - $app->defaults(openapi_spec => ...);
    # - $route->to(openapi_spec => ...);
    $c->stash(openapi_spec => JSON::Validator->new->schema($petstore->to_string)->bundle);

    # render_spec() can be called with $openapi_path
    $c->openapi->render_spec;
  };

=head1 DESCRIPTION

L<Mojolicious::Plugin::OpenAPI::SpecRenderer> will enable
L<Mojolicious::Plugin::OpenAPI> to render the specification in both HTML and
JSON format. It can also be used L</Standalone> if you just want to render
the specification, and not add any API routes to your application.

The human readable format focus on making the documentation printable, so you
can easily share it with third parties as a PDF. If this documentation format
is too basic or has missing information, then please
L<report in|https://github.com/jhthorsen/mojolicious-plugin-openapi/issues>
suggestions for enhancements.

=head1 HELPERS

=head2 openapi.render_spec

  $c = $c->openapi->render_spec;
  $c = $c->openapi->render_spec($openapi_path);
  $c = $c->openapi->render_spec("/user/{id}");

Used to render the specification as either "html" or "json". Set the
L<Mojolicious/stash> variable "format" to change the format to render.

Will render the whole specification by default, but can also render
documentation for a given OpenAPI path.

=head1 METHODS

=head2 register

  $doc->register($app, $openapi, \%config);

Adds the features mentioned in the L</DESCRIPTION>.

C<%config> is the same as passed on to
L<Mojolicious::Plugin::OpenAPI/register>. The following keys are used by this
plugin:

=head3 render_specification

Render the whole specification as either HTML or JSON from "/:basePath".
Example if C<basePath> in your specification is "/api":

  GET https://api.example.com/api.html
  GET https://api.example.com/api.json

Disable this feature by setting C<render_specification> to C<0>.

=head3 render_specification_for_paths

Render the specification from individual routes, using the OPTIONS HTTP method.
Example:

  OPTIONS https://api.example.com/api/some/path.json
  OPTIONS https://api.example.com/api/some/path.json?method=post

Disable this feature by setting C<render_specification_for_paths> to C<0>.

=head1 SEE ALSO

L<Mojolicious::Plugin::OpenAPI>

=cut

__DATA__
@@ mojolicious/plugin/openapi/header.html.ep
<h1 id="title"><%= $spec->{info}{title} || 'No title' %></h1>
<p class="version"><span>Version</span> <span class="version"><%= $spec->{info}{version} %> - OpenAPI <%= $spec->{swagger} || $spec->{openapi} %></span></p>

@@ mojolicious/plugin/openapi/intro.html.ep
% if ($spec->{info}{description}) {
<h2 id="description"><a href="#title">Description</a></h2>
<div class="description">
  %== $markdown->($spec->{info}{description})
</div>
% }

% if ($spec->{info}{termsOfService}) {
<h2 id="terms-of-service"><a href="#title">Terms of service</a></h2>
<p class="terms-of-service">
  %= $spec->{info}{termsOfService}
</p>
% }
@@ mojolicious/plugin/openapi/foot.html.ep
<!-- default foot -->
@@ mojolicious/plugin/openapi/footer.html.ep
% my $contact = $spec->{info}{contact};
% my $license = $spec->{info}{license};
<h2 id="license"><a href="#title">License</a></h2>
% if ($license->{name}) {
<p class="license"><a href="<%= $license->{url} || '' %>"><%= $license->{name} %></a></p>
% } else {
<p class="no-license">No license specified.</p>
% }
<h2 id="contact"<a href="#title">Contact information</a></h2>
% if ($contact->{email}) {
<p class="contact-email"><a href="mailto:<%= $contact->{email} %>"><%= $contact->{email} %></a></p>
% }
% if ($contact->{url}) {
<p class="contact-url"><a href="mailto:<%= $contact->{url} %>"><%= $contact->{url} %></a></p>
% }
@@ mojolicious/plugin/openapi/head.html.ep
<title><%= $spec->{info}{title} || 'No title' %></title>
<meta charset="utf-8">
<meta http-equiv="X-UA-Compatible" content="chrome=1">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=2.0">
@@ mojolicious/plugin/openapi/human.html.ep
% if ($spec->{summary}) {
<p class="spec-summary"><%= $spec->{summary} %></p>
% }
% if ($spec->{description}) {
<div class="spec-description"><%== $markdown->($spec->{description}) %></div>
% }
% if (!$spec->{description} and !$spec->{summary}) {
<p class="op-summary op-doc-missing">This resource is not documented.</p>
% }
@@ mojolicious/plugin/openapi/parameters.html.ep
% my $has_parameters = @{$op->{parameters} || []};
% my $body;
<h4 class="op-parameters">Parameters</h3>
% if ($has_parameters) {
<table class="op-parameters">
  <thead>
    <tr>
      <th>Name</th>
      <th>In</th>
      <th>Type</th>
      <th>Required</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
% }
% for my $p (@{$op->{parameters} || []}) {
  % $body = $p->{schema} if $p->{in} eq 'body';
  <tr>
    % if ($spec->{parameters}{$p->{name}}) {
      <td><a href="#ref-parameters-<%= $esc->($p->{name}) %>"><%= $p->{name} %></a></td>
    % } else {
      <td><%= $p->{name} %></td>
    % }
    <td><%= $p->{in} %></td>
    <td><%= $p->{type} || $p->{schema}{type} %></td>
    <td><%= $p->{required} ? "Yes" : "No" %></td>
    <td><%== $p->{description} ? $markdown->($p->{description}) : "" %></td>
  </tr>
% }
% if ($has_parameters) {
  </tbody>
</table>
% } else {
<p class="op-parameters">This resource has no input parameters.</p>
% }
% if ($body) {
<h4 class="op-parameter-body">Body</h4>
<pre class="op-parameter-body"><%= $serialize->($body) %></pre>
% }
% if ($op->{requestBody}) {
<h4 class="op-parameter-body">requestBody</h4>
<pre class="op-parameter-body"><%= $serialize->($op->{requestBody}{content}) %></pre>
% }
@@ mojolicious/plugin/openapi/response.html.ep
% for my $code (sort { $a cmp $b } keys %{$op->{responses}}) {
  % next if $code =~ $X_RE;
  % my $res = $op->{responses}{$code};
<h4 class="op-response">Response <%= $code %></h3>
%= include "mojolicious/plugin/openapi/human", spec => $res
<pre class="op-response"><%= $serialize->($res->{schema} || $res->{content}) %></pre>
% }
@@ mojolicious/plugin/openapi/resource.html.ep
<h3 id="op-<%= lc $method %><%= $esc->($path) %>" class="op-path <%= $op->{deprecated} ? "deprecated" : "" %>"><a href="#title"><%= uc $method %> <%= $spec->{basePath} %><%= $path %></a></h3>
% if ($op->{deprecated}) {
<p class="op-deprecated">This resource is deprecated!</p>
% }
% if ($op->{operationId}) {
<p class="op-id"><b>Operation ID:</b> <span><%= $op->{operationId} %></span></p>
% }
%= include "mojolicious/plugin/openapi/human", spec => $op
%= include "mojolicious/plugin/openapi/parameters", op => $op
%= include "mojolicious/plugin/openapi/response", op => $op
@@ mojolicious/plugin/openapi/references.html.ep
% use Mojo::ByteStream 'b';
<h2 id="references"><a href="#title">References</a></h2>
% for my $key (sort { $a cmp $b } keys %{$spec->{definitions} || {}}) {
  % next if $key =~ $X_RE;
  <h3 id="ref-definitions-<%= lc $esc->($key) %>"><a href="#title">#/definitions/<%= $key %></a></h3>
  <pre class="ref"><%= $serialize->($spec->{definitions}{$key}) %></pre>
% }
% for my $type (sort { $a cmp $b } keys %{$spec->{components} || {}}) {
  % for my $key (sort { $a cmp $b } keys %{$spec->{components}{$type} || {}}) {
    % next if $key =~ $X_RE;
    <h3 id="ref-components-<%= lc $esc->($type) %>-<%= lc $esc->($key) %>"><a href="#title">#/components/<%= $type %>/<%= $key %></a></h3>
    <pre class="ref"><%= $serialize->($spec->{components}{$type}{$key}) %></pre>
  % }
% }
% for my $key (sort { $a cmp $b } keys %{$spec->{parameters} || {}}) {
  % next if $key =~ $X_RE;
  % my $item = $spec->{parameters}{$key};
  <h3 id="ref-parameters-<%= lc $esc->($key) %>"><a href="#title">#/parameters/<%= $key %> - "<%= $item->{name} %>"</a></h3>
  <p><%= $item->{description} || 'No description.' %></p>
  <ul>
    <li>In: <%= $item->{in} %></li>
    <li>Type: <%= $item->{type} %><%= $item->{format} ? " / $item->{format}" : "" %><%= $item->{pattern} ? " / $item->{pattern}" : ""%></li>
    % if ($item->{exclusiveMinimum} || $item->{exclusiveMaximum} || $item->{minimum} || $item->{maximum}) {
      <li>
        Min / max:
        <%= $item->{exclusiveMinimum} ? "$item->{exclusiveMinimum} <" : $item->{minimum} ? "$item->{minimum} <=" : b("&infin; <=") %>
        value
        <%= $item->{exclusiveMaximum} ? "< $item->{exclusiveMaximum}" : $item->{maximum} ? "<= $item->{maximum}" : b("<= &infin;") %>
      </li>
    % }
    % if ($item->{minLength} || $item->{maxLength}) {
      <li>
        Min / max:
        <%= $item->{minLength} ? "$item->{minLength} <=" : b("&infin; <=") %>
        length
        <%= $item->{maxLength} ? "<= $item->{maxLength}" : b("<= &infin;") %>
      </li>
    % }
    % if ($item->{minItems} || $item->{maxItems}) {
      <li>
        Min / max:
        <%= $item->{minItems} ? "$item->{minItems} <=" : b("&infin; <=") %>
        items
        <%= $item->{maxItems} ? "<= $item->{maxItems}" : b("<= &infin;") %>
      </li>
    % }
    % for my $k (qw(collectionFormat uniqueItems multipleOf enum)) {
      % next unless $item->{$k};
      <li><%= ucfirst $k %>: <%= ref $item->{$k} ? $serialize->($item->{$k}) : $item->{$k} %></li>
    % }
    <li>Required: <%= $item->{required} ? 'Yes.' : 'No.' %></li>
    <li><%= defined $item->{default} ? "Default: " . $serialize->($item->{default}) : 'No default value.' %></li>
  </ul>
  % for my $k (qw(items schema)) {
    % next unless $item->{$k};
    <pre class="ref"><%= $serialize->($item->{$k}) %></pre>
  % }
% }

@@ mojolicious/plugin/openapi/resources.html.ep
<h2 id="resources"><a href="#title">Resources</a></h2>

% if (exists $spec->{servers}) {
  <h3 id="servers"><a href="#title">Servers</a></h3>
  <ul class="unstyled">
  % for my $server (@{$spec->{servers}}){
    <li><a href="<%= $server->{url} %>"><%= $server->{url} %></a><%= $server->{description} ? ' - '.$server->{description} : '' %></li>
  % }
  </ul>
% } else {
  % my $schemes = $spec->{schemes} || ["http"];
  % my $url = Mojo::URL->new("http://$spec->{host}");
  <h3 id="base-url"><a href="#title">Base URL</a></h3>
  <ul class="unstyled">
  % for my $scheme (@$schemes) {
    % $url->scheme($scheme);
    <li><a href="<%= $url %>"><%= $url %></a></li>
  % }
  </ul>
% }

% for my $path (sort { length $a <=> length $b } keys %{$spec->{paths}}) {
  % next if $path =~ $X_RE;
  % for my $http_method (sort { $a cmp $b } keys %{$spec->{paths}{$path}}) {
    % next if $http_method =~ $X_RE or $http_method eq 'parameters';
    % my $op = $spec->{paths}{$path}{$http_method};
    %= include "mojolicious/plugin/openapi/resource", method => $http_method, op => $op, path => $path
  % }
% }
@@ mojolicious/plugin/openapi/toc.html.ep
<ol id="toc">
  % if ($spec->{info}{description}) {
  <li class="for-description"><a href="#description">Description</a></a>
  % }
  % if ($spec->{info}{termsOfService}) {
  <li class="for-terms"><a href="#terms-of-service">Terms of service</a></li>
  % }
  <li class="for-resources">
    <a href="#resources">Resources</a>
    <ol>
    % for my $path (sort { length $a <=> length $b } keys %{$spec->{paths}}) {
      % next if $path =~ $X_RE;
      % for my $method (sort { $a cmp $b } keys %{$spec->{paths}{$path}}) {
        % next if $method =~ $X_RE;
        <li><a href="#op-<%= lc $method %><%= $esc->($path) %>"><span class="method"><%= uc $method %></span> <%= $spec->{basePath} %><%= $path %></a></li>
      % }
    % }
    </ol>
  </li>
  <li class="for-references">
    <a href="#references">References</a>
    <ol>
    % for my $key (sort { $a cmp $b } keys %{$spec->{definitions} || {}}) {
      % next if $key =~ $X_RE;
      <li><a href="#ref-definitions-<%= lc $esc->($key) %>">#/definitions/<%= $key %></a></li>
    % }
    % for my $type (sort { $a cmp $b } keys %{$spec->{components} || {}}) {
      % for my $key (sort { $a cmp $b } keys %{$spec->{components}{$type} || {}}) {
        % next if $key =~ $X_RE;
        <li><a href="#ref-components-<%= lc $esc->($type) %>-<%= lc $esc->($key) %>">#/components/<%= $type %>/<%= $key %></a></li>
      % }
    % }
    % for my $key (sort { $a cmp $b } keys %{$spec->{parameters} || {}}) {
      % next if $key =~ $X_RE;
      <li><a href="#ref-parameters-<%= lc $esc->($key) %>">#/parameters/<%= $key %></a></li>
    % }
    </ol>
  </li>
  <li class="for-license"><a href="#license">License</a></li>
  <li class="for-contact"><a href="#contact">Contact</a></li>
</ol>
@@ mojolicious/plugin/openapi/layout.html.ep
<!doctype html>
<html lang="en">
<head>
  %= include "mojolicious/plugin/openapi/head"
  %= include "mojolicious/plugin/openapi/style"
</head>
<body>
<div class="container openapi-container">
  <header class="openapi-header">
    %= include 'mojolicious/plugin/openapi/header'
  </header>

  <nav class="openapi-nav">
    %= include 'mojolicious/plugin/openapi/logo'
    %= include 'mojolicious/plugin/openapi/toc'
  </nav>

  <article class="openapi-spec">
    <section class="openapi-spec_intro">
      %= include 'mojolicious/plugin/openapi/intro'
    </section>
    <section class="openapi-spec_resources">
      %= include 'mojolicious/plugin/openapi/resources'
    </section>
    <section class="openapi-spec_references">
      %= include 'mojolicious/plugin/openapi/references'
    </section>
  </article>

  <footer class="openapi-footer">
    %= include 'mojolicious/plugin/openapi/footer'
  </footer>
</div>

%= include "mojolicious/plugin/openapi/renderjson"
%= include "mojolicious/plugin/openapi/scrollspy"
%= include "mojolicious/plugin/openapi/foot"
</body>
</html>
@@ mojolicious/plugin/openapi/renderjson.html.ep
<script>
var module,window,define,renderjson=function(){function n(a,u,c,p,f){var y=c?"":u,_=function(n,o,a,u,c){var _,d=l(u),h=function(){_||e(d.parentNode,_=r(c(),i(f.hide,"disclosure",function(){_.style.display="none",d.style.display="inline"}))),_.style.display="inline",d.style.display="none"};e(d,i(f.show,"disclosure",h),t(u+" syntax",n),i(o,null,h),t(u+" syntax",a));var g=e(l(),s(y.slice(0,-1)),d);return p>0&&"string"!=u&&h(),g};return null===a?t(null,y,"keyword","null"):void 0===a?t(null,y,"keyword","undefined"):"string"==typeof a&&a.length>f.max_string_length?_('"',a.substr(0,f.max_string_length)+" ...",'"',"string",function(){return e(l("string"),t(null,y,"string",JSON.stringify(a)))}):"object"!=typeof a||[Number,String,Boolean,Date].indexOf(a.constructor)>=0?t(null,y,typeof a,JSON.stringify(a)):a.constructor==Array?0==a.length?t(null,y,"array syntax","[]"):_("["," ... ","]","array",function(){for(var r=e(l("array"),t("array syntax","[",null,"\n")),o=0;o<a.length;o++)e(r,n(f.replacer.call(a,o,a[o]),u+"  ",!1,p-1,f),o!=a.length-1?t("syntax",","):[],s("\n"));return e(r,t(null,u,"array syntax","]")),r}):o(a,f.property_list)?t(null,y,"object syntax","{}"):_("{","...","}","object",function(){var r=e(l("object"),t("object syntax","{",null,"\n"));for(var o in a)var i=o;var c=f.property_list||Object.keys(a);f.sort_objects&&(c=c.sort());for(var y in c)(o=c[y])in a&&e(r,t(null,u+"  ","key",'"'+o+'"',"object syntax",": "),n(f.replacer.call(a,o,a[o]),u+"  ",!0,p-1,f),o!=i?t("syntax",","):[],s("\n"));return e(r,t(null,u,"object syntax","}")),r})}var t=function(){for(var n=[];arguments.length;)n.push(e(l(Array.prototype.shift.call(arguments)),s(Array.prototype.shift.call(arguments))));return n},e=function(){for(var n=Array.prototype.shift.call(arguments),t=0;t<arguments.length;t++)arguments[t].constructor==Array?e.apply(this,[n].concat(arguments[t])):n.appendChild(arguments[t]);return n},r=function(n,t){return n.insertBefore(t,n.firstChild),n},o=function(n,t){var e=t||Object.keys(n);for(var r in e)if(Object.hasOwnProperty.call(n,e[r]))return!1;return!0},s=function(n){return document.createTextNode(n)},l=function(n){var t=document.createElement("span");return n&&(t.className=n),t},i=function(n,t,e){var r=document.createElement("a");return t&&(r.className=t),r.appendChild(s(n)),r.href="#",r.onclick=function(n){return e(),n&&n.stopPropagation(),!1},r},a=function t(r){var o=Object.assign({},t.options);o.replacer="function"==typeof o.replacer?o.replacer:function(n,t){return t};var s=e(document.createElement("pre"),n(r,"",!1,o.show_to_level,o));return s.className="renderjson",s};return a.set_icons=function(n,t){return a.options.show=n,a.options.hide=t,a},a.set_show_to_level=function(n){return a.options.show_to_level="string"==typeof n&&"all"===n.toLowerCase()?Number.MAX_VALUE:n,a},a.set_max_string_length=function(n){return a.options.max_string_length="string"==typeof n&&"none"===n.toLowerCase()?Number.MAX_VALUE:n,a},a.set_sort_objects=function(n){return a.options.sort_objects=n,a},a.set_replacer=function(n){return a.options.replacer=n,a},a.set_property_list=function(n){return a.options.property_list=n,a},a.set_show_by_default=function(n){return a.options.show_to_level=n?Number.MAX_VALUE:0,a},a.options={},a.set_icons("⊕","⊖"),a.set_show_by_default(!1),a.set_sort_objects(!1),a.set_max_string_length("none"),a.set_replacer(void 0),a.set_property_list(void 0),a}();define?define({renderjson:renderjson}):(module||{}).exports=(window||{}).renderjson=renderjson;
(function(w, d) {
  renderjson.set_show_to_level("all");
  renderjson.set_sort_objects(true);
  renderjson.set_max_string_length(100);

  var els = d.querySelectorAll("pre");
  for (var i = 0; i < els.length; i++) {
    els[i].parentNode.replaceChild(renderjson(JSON.parse(els[i].innerText)), els[i]);
  }

  els = d.querySelectorAll(".key");
  for (var i = 0; i < els.length; i++) {
    if (els[i].textContent != '"$ref"') continue;
    var link = els[i].nextElementSibling;
    while (link = link.nextElementSibling) {
      if (!link.className || !link.className.match(/\bstring\b/)) continue;
      var a = d.createElement("a");
      var href = link.textContent.replace(/"/g, "");
      a.className = link.className;
      a.textContent = link.textContent;
      a.href = href.match(/^#/) ? "#ref-" + href.replace(/\W/g, "-").substring(2).toLowerCase() : href;
      link.parentNode.replaceChild(a, link);
    }
  }
})(window, document);
</script>
@@ mojolicious/plugin/openapi/scrollspy.html.ep
<script>
(function() {
  var aEls = document.querySelectorAll('.openapi-nav a');
  var firstH2 = document.querySelector('h2');
  var headings = document.querySelectorAll('h3[id]');

  var spy = function() {
    var innerHeight = window.innerHeight;
    var offsetTop = parseInt(innerHeight / 2.3, 10);
    var scrollPosition = document.documentElement.scrollTop || document.body.scrollTop;
    var i = 0;

    // Do not run this method too often
    if (spy.tid) clearTimeout(spy.tid);
    delete spy.tid;

    // Find the next heading that is not scrolled into view
    if (firstH2.offsetTop < scrollPosition) {
      for (i = 0; i < headings.length; i++) {
        if (headings[i].offsetTop >= scrollPosition + innerHeight - offsetTop) break;
      }
    }

    if (i > 0) i--;

    // Find a corresponding link in the nav and style it
    var id = headings[i] && headings[i].id || '';
    var aEl = document.querySelector('.openapi-nav a[href$="#' + id + '"]');

    for (i = 0; i < aEls.length; i++) {
      aEls[i].parentNode.classList[aEls[i] == aEl ? 'add' : 'remove']('is-active');
    }
  };

  ['click', 'resize', 'scroll'].forEach(function(name) {
    window.addEventListener(name, function() {
      return spy.tid || (spy.tid = setTimeout(spy, 100));
    });
  });

  spy();
})();
</script>
@@ mojolicious/plugin/openapi/style.html.ep
<style>
  * { box-sizing: border-box; }
  html, body {
    background: #f7f7f7;
    font-family: 'Gotham Narrow SSm','Helvetica Neue',Helvetica,sans-serif;
    font-size: 16px;
    color: #222;
    line-height: 1.4em;
    margin: 0;
    padding: 0;
  }
  body {
    padding: 1rem;
  }
  a { color: #508a25; text-decoration: underline; word-break: break-word; }
  a:hover { text-decoration: none; }
  h1, h2, h3, h4 { font-family: Verdana; color: #403f41; font-weight: bold; line-height: 1.2em; margin: 1em 0; }
  h1 a, h2 a, h3 a, h4 a { text-decoration: none; color: inherit; }
  h1 a:hover, h2 a:hover, h3 a:hover, h4 a:hover { text-decoration: underline; }
  h1 { font-size: 2.4em; }

  h2 {
    font-size: 1.8em;
    border-bottom: 2px solid #cfd4c5;
    padding: 0.5rem 0;
    margin-top: 1.5em;
  }

  h3 { font-size: 1.4em; }
  h4 { font-size: 1.1em; }
  table {
    margin: 0em -0.5em;
    width: 100%;
    border-collapse: collapse;
  }
  td, th {
    vertical-align: top;
    text-align: left;
    padding: 0.5em;
  }
  th {
    font-weight: bold;
    border-bottom: 1px solid #ccc;
  }
  td p, th p {
    margin: 0;
  }
  ol,
  ul {
    margin: 0;
    padding: 0 1.5em;
  }
  ul.unstyled {
    list-style: none;
    padding: 0;
  }
  p {
    margin: 1em 0;
  }

  pre {
    background: #e8eae2;
    font-size: 0.9rem;
    line-height: 1.2em;
    letter-spacing: -0.02em;
    border-left: 4px solid #6cab3e;
    padding: 0.5em;
    margin: 1rem 0rem;
    overflow: auto;
  }

  .openapi-nav a {
    text-decoration: none;
    line-height: 1.5rem;
    white-space: nowrap;
  }

  .openapi-logo { display: none; }
  .openapi-nav ol { margin: 0.2rem 0 0.5rem 0; }

  .openapi-container { max-width: 50rem; margin: 0 auto; }
  p.version { margin: -1rem 0 2em 0; }
  p.op-deprecated { color: #c00; }

  h3.op-path { margin-top: 2em; }
  h2 + h3.op-path { margin-top: 1em; }

  .renderjson .disclosure { display: none; }
  .renderjson .syntax     { color: #002b36; }
  .renderjson .string     { color: #073642; }
  .renderjson .number     { color: #2aa198; }
  .renderjson .boolean    { color: #d33682; }
  .renderjson .key        { color: #3c8607; }
  .renderjson .keyword    { color: #b58900; }

  @media only screen and (min-width: 60rem) {
    body {
      padding: 0;
    }

    .openapi-container {
      max-width: 70rem;
    }

    .openapi-nav {
      padding: 1.4rem 0 3rem 1rem;
      max-width: 18rem;
      height: 100vh;
      overflow: auto;
      -webkit-overflow-scrolling: touch;
      position: fixed;
      top: 0;
    }

    .openapi-logo {
      display: block;
      margin-bottom: 1rem;
    }

    .openapi-nav ol {
      list-style: none;
      padding: 0;
      margin: 0;
    }

    .openapi-nav li a {
      margin: -0.1rem -0.2rem;
      padding: 0.1rem 0.4rem;
      display: block;
    }

    .openapi-nav li a:hover {
      background: #dbe4cd;
      text-decoration: none;
    }

    .openapi-nav > ol > li > a {
      color: #403f41;
      font-weight: bold;
      font-size: 1.1rem;
      line-height: 1.8em;
    }

    .openapi-nav li.is-active a {
      background: #e3e8d4;
    }

    .openapi-nav .method {
      font-size: 0.8rem;
      color: #222;
      width: auto;
    }

    .openapi-header,
    .openapi-spec {
      padding-left: 21rem;
      padding-right: 1rem;
    }
  }
</style>
@@ mojolicious/plugin/openapi/logo.html.ep
<a href="#title" class="openapi-logo">
  %= image '/mojolicious/plugin/openapi/logo.png', alt => 'OpenAPI Logo'
</a>
@@ mojolicious/plugin/openapi/logo.png (base64)
iVBORw0KGgoAAAANSUhEUgAAAMgAAAA5CAMAAABESJQQAAAABGdBTUEAALGPC/xhBQAAACBjSFJN
AAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAC+lBMVEVHcExXYExNTE5GREZH
RkhLSUxZXFMAAElLSkxEQ0VDQkRDQkNDQkRDQkRFRUZMSk1LSkxJR0pRU09DQkREQ0VOT0tUVFFE
Q0RHRkd8gHxNS05CQUNUVFF2tk95qlByqkt2rU5vp0hfZ09ZZkdLS0xDQkRCQUN2qU5wqUptp0Zt
p0ZupkZspkRwqEhLXDJNXDNOXTNOXTROXTRSYDdYZz5nkVNEQ0VNTE9wqEpup0ZrpUNupEZQXzVM
WzFSYThSYjhgYVyArlZwp0htpkZNXDFNXDNRYDdeZk1RUU1EQ0VDQkSi01KVyEhtp0VSYDdCQUNL
SkuWyT+XykJ0q0xNXDJYXVBYWlVFREZFREZCQkOtx22YykWWyUCVyD2VyD6Wx0ltpkZMS05FREZJ
SEmXykKWyUB8rE1NXDNFREZCQUNGRUdFREZfX19XZztOXTRth0KWyUGUyD2XykRRYjdOTU9PXTRw
iUWVyD+Mu0xtp0dNXDJPXjVMS01PXjSWyUGYykN2qlBspkRRUFJbXlhPXjSUyT5PTlBRYDdYZz1N
XDFspkRRYTdNXDFSXj1tg0CVyT6Zy0VaX1JEQ0VQXzZDQURSYjlxoU1wqElSYDdSYTmXykdSYThT
YTlJSEpJR0lCQUNJSEpEREVRUVNKSEtYWFhPTlFOTlBNTE1GRkdISElHR0lxcHJxbXFEREVcXFVh
YGJycXJ7e354eHxsa25JSUpFQ0Y/PkpBQUNIR0hAQEdIR0lKSUtHRkiJrmVEQUSenpyhs46Vm4Nv
qElwqUpGRUdEQ0VIR0lKSEpHRkiWykGVyD5CQUNCQUNHRkdJSUqn1l6Vxklvp0dTU1VBQUVEQERE
Q0VKSkyYy0hrpkNfX2JGRUdPT1B0pk9rpkRHRkhFREVJSEtEREVLSkyVyD+WyUB1pFBZWVqVxU91
olBup0hnZ2ptpkZDQ0NKSkuXyUN0plBMWzKXxkyXyERXV1lKSUtTYThPTVBKSktDQUNCQUNrpUNM
WzGUyD3///+AqxLvAAAA+XRSTlMAE0FicjwRAkfV7/j97cgzYVkE8eEqDLmiAiTkIgoTGi0yDi43
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
KzAwOjAw+374IAAAAABJRU5ErkJggg==
