#!/usr/bin/perl
# SM1402 (triage T-92): A NOTIFY SETTING FOR A FORM THAT DOES NOT EXIST IS
# REFUSED. `set_form_notify` (MCP) and `form-notify-save` (API) asked only
# whether the caller reaches the form, and action_form_notify_save wrote
# lazysite/forms/<name>.conf for any name - a conf for a form nobody made. A
# name that is neither registered (its conf exists) nor bound on a page is
# refused naming create_form; a registered form still saves, and so does one a
# page binds whose conf is not there yet.
#
# Reverted, the first subtest fails: the conf is written for the ghost.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Handlers ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

my $d = site_tempdir();
make_path("$d/lazysite/forms");
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n  - id: jsonl\n    type: file\n    path: lazysite/forms/submissions\n" );
spit( "$d/lazysite/forms/contact.conf", "targets:\n  - handler: jsonl\n" );
spit( "$d/join.md", "---\ntitle: Join\nform: signup\n---\n:::form\nname: text\n:::\n" );
$Lazysite::Handlers::DOCROOT = $d;
sub save { Lazysite::Handlers::action_form_notify_save(@_) }

subtest 'a name no conf registers and no page binds is refused, naming create_form' => sub {
    my $r = save( 'ghost', 'off' );
    ok( !$r->{ok}, 'refused' ) or diag explain $r;
    is( $r->{kind},  'not-found', 'as not-found' );
    is( $r->{field}, 'form',      'naming the field' );
    like( $r->{error}, qr/no form 'ghost'/,   'and the name' );
    like( $r->{error}, qr/create_form first/, 'and what makes one' );
    ok( !-e "$d/lazysite/forms/ghost.conf", 'and nothing was written' );
};

subtest 'a registered form still saves' => sub {
    my $r = save( 'contact', 'full' );
    ok( $r->{ok}, 'saved' ) or diag explain $r;
    like( slurp("$d/lazysite/forms/contact.conf"), qr/^notify: full$/m, 'into its conf' );
};

subtest 'a form a page binds, whose conf is not there yet, is a form' => sub {
    my $r = save( 'signup', 'on' );
    ok( $r->{ok}, 'saved' ) or diag explain $r;
    like( slurp("$d/lazysite/forms/signup.conf") // '', qr/^notify: on$/m, 'and its conf is made' );
};

done_testing;
