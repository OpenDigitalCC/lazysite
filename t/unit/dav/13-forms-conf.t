#!/usr/bin/perl
# A per-form dispatch config (lazysite/forms/<name>.conf) is agent-editable over
# WebDAV with `manage_forms` (0.8.1 cross-plane consistency: WebDAV previously
# used manage_config; the control-API handler-save / MCP bind_form already
# required manage_forms, and Capabilities.pm documents manage_forms as owning
# lazysite/forms/<name>.conf). It only references operator-defined handlers, no
# secrets. smtp.conf / handlers.conf / the submissions store stay denied, and
# without manage_forms even the dispatch conf is denied.
#
# SM842: the conf is SHAPE-CHECKED on the way in. Its targets name handlers
# that exist and nothing else - the rule form-targets-save and bind_form apply
# - so an inline target cannot come back through the file door, and a form
# cannot be pointed at a handler nobody created. schedule.conf, which says
# what the timer calls, is denied beside handlers.conf.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_dav_site run_dav dav_users_tool grant_caps revoke_caps);

my $s = setup_dav_site( caps => ['webdav'] );
make_path("$s->{docroot}/lazysite/forms");
{
    open my $hc, '>', "$s->{docroot}/lazysite/forms/handlers.conf" or die $!;
    print {$hc} "handlers:\n  - id: local-storage\n    type: file\n    name: Local\n";
    close $hc;
}
my $a = $s->{auth};

sub put { run_dav( $s->{docroot}, 'PUT', $_[0], body => ( $_[1] // 'x' ), HTTP_AUTHORIZATION => $a ) }
sub get { run_dav( $s->{docroot}, 'GET', $_[0], HTTP_AUTHORIZATION => $a ) }

# manage_config alone does NOT grant the dispatch conf (the realignment)
grant_caps( $s->{docroot}, $s->{user}, 'manage_config' );
is( put('/lazysite/forms/enquire.conf')->{code}, 403,
    'forms/<name>.conf still denied with only manage_config (WebDAV now matches API/MCP: forms = manage_forms)' );

grant_caps( $s->{docroot}, $s->{user}, 'manage_forms' );

# the dispatch conf is writable + readable with manage_forms
my $w = put( '/lazysite/forms/enquire.conf', "targets:\n  - handler: local-storage\n" );
ok( $w->{code} == 201 || $w->{code} == 204, 'forms/<name>.conf PUT allowed with manage_forms' );
is( get('/lazysite/forms/enquire.conf')->{code}, 200, 'and readable back' );

# the secret + data files stay denied
is( put('/lazysite/forms/smtp.conf')->{code},     403, 'smtp.conf write denied (credentials)' );
is( get('/lazysite/forms/smtp.conf')->{code},     403, 'smtp.conf read denied' );
is( put('/lazysite/forms/handlers.conf')->{code}, 403, 'handlers.conf write denied (handler defs)' );
is( put('/lazysite/forms/schedule.conf')->{code}, 403, 'schedule.conf write denied (what the timer calls)' );

# SM842: the shape check.
my $inline = put( '/lazysite/forms/enquire.conf', "targets:\n  - type: webhook\n    url: https://hook.example/x\n" );
is( $inline->{code}, 422, 'an inline target is refused - a form names handlers only' );
like( $inline->{body} // '', qr/not a handler reference/, 'and the answer says what a target must be' );
my $ghost = put( '/lazysite/forms/enquire.conf', "targets:\n  - handler: nobody-made-this\n" );
is( $ghost->{code}, 422, 'a handler that does not exist is refused' );
like( $ghost->{body} // '', qr/no handler 'nobody-made-this'.*local-storage/s,
    'naming the handlers that do' );
like( get('/lazysite/forms/enquire.conf')->{body} // '', qr/handler: local-storage/,
    'and the refused writes left the good config in place' );
is( put('/lazysite/forms/submissions/e.json')->{code}, 403, 'submissions store denied' );

# without manage_forms, even the dispatch conf is denied
my $s2 = setup_dav_site( user => 'plain', caps => ['webdav'] );
my $d2 = run_dav( $s2->{docroot}, 'PUT', '/lazysite/forms/enquire.conf',
    body => 'x', HTTP_AUTHORIZATION => $s2->{auth} );
is( $d2->{code}, 403, 'no manage_forms -> dispatch conf denied' );

done_testing();
