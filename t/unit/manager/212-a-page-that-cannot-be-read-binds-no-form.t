#!/usr/bin/perl
# SM976 Q15h (ruled 2026-10-09, "Refuse + walker skips"): a page whose reading
# dies binds no form, and the death is logged, so one such page cannot stop
# the form rule's walk.
#
# The finding was tmp/q15g-walker-die-probe.pl: one page with `form:\xFF leads`
# - bytes that are not UTF-8, which reach the disk by a door that writes no
# caller's bytes (git, SSH, a backup restore) - made form_bindings die, and with
# it caller_may_reach_form and the write rule: every form verb, and every write
# of a page binding a form, errored for every confined caller. The processor's
# own parse dies on such a page too, and renders nothing for it.
use strict;
use warnings;
no warnings 'utf8';    # the page under test is not UTF-8 by design
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Manager::Common qw(form_bindings caller_may_reach_form form_bind_refusal page_form_or_none);

local $ENV{LAZYSITE_FORWARD_DIAGNOSTICS} = 'off';
local $ENV{LAZYSITE_LOG_LEVEL}           = 'INFO';

my $d = site_tempdir();
make_path( "$d/lazysite/forms", "$d/sites/alpha" );
sub spit { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
spit( "$d/lazysite/lazysite.conf", "site_name: T\nalias_hosts: alpha.test\nalias.alpha.test.content_root: sites/alpha\n" );
spit( "$d/sites/alpha/c.md",       "---\ntitle: C\nform: mine\n---\n" );
spit( "$d/p.md",                   "---\ntitle: P\nform: prim\n---\n" );
spit( "$d/lazysite/forms/$_.conf", "targets:\n" ) for qw(mine prim);
$Lazysite::Manager::Common::DOCROOT = $d;
my @alpha = ( scopes => ['sites/alpha'] );

# What the code under test writes to STDERR (log_event's sink), and its answer.
sub with_log {
    my ($code) = @_;
    my $log = "$d/stderr.log";
    open my $save, '>&', \*STDERR or die $!;
    open STDERR,   '>',  $log     or die $!;
    my @r   = eval { $code->() };
    my $err = $@;
    open STDERR, '>&', $save or die $!;
    open my $fh, '<',  $log  or die $!;
    my $text = do { local $/; <$fh> };
    return ( $err, $text, @r );
}

# The page: put there as bytes, as git or SSH would.
spit( "$d/sites/alpha/bad.md", "---\nform:\xFF leads\n---\n" );

subtest 'the walk survives the page and still finds every other binding' => sub {
    my ( $err, $log, $b ) = with_log( sub { form_bindings() } );
    is( $err, '', 'form_bindings does not die' );
    is_deeply( $b, { mine => ['sites/alpha/c.md'], prim => ['p.md'] }, 'and files every other page as before' );
    like( $log, qr/\[WARN\].*\[form-rule\] a page whose front matter cannot be read binds no form/,
        'the page is logged, at WARN (forwarded by default, SM932)' );
    like( $log, qr/page=sites\/alpha\/bad\.md/, '...naming it by its docroot-relative path' );
    like( $log, qr/error=Malformed UTF-8 character/, '...and why its reading died' );
};

subtest 'the rules that ask the walk answer as on a clean site' => sub {
    my ( $err, undef, $mine, $prim ) = with_log( sub {
            ( caller_may_reach_form( 'mine', @alpha ) ? 1 : 0, caller_may_reach_form( 'prim', @alpha ) ? 1 : 0 ) } );
    is( $err,  '', 'caller_may_reach_form does not die' );
    is( $mine, 1,  'alpha reaches the form bound on its own page' );
    is( $prim, 0,  'and not the primary\'s' );
    my ( $err2, undef, @no ) = with_log( sub { form_bind_refusal( 'sites/alpha/n.md', "---\nform: prim\n---\n", @alpha ) } );
    is( $err2, '', 'the write rule does not die' );
    ok( scalar @no, 'and still refuses a new page binding the primary\'s form' );
    my ( undef, undef, @yes ) = with_log( sub { form_bind_refusal( 'sites/alpha/n.md', "---\nform: mine\n---\n", @alpha ) } );
    is( scalar @yes, 0, 'and allows one binding its own' );
};

subtest 'the page itself binds nothing, so writing over it is judged as a new page' => sub {
    my ( $err, $log, @no ) = with_log( sub { form_bind_refusal( 'sites/alpha/bad.md', "---\nform: prim\n---\n", @alpha ) } );
    is( $err, '', 'the write rule reads the current page without dying' );
    ok( scalar @no, 'and refuses it binding the primary\'s form' );
    like( $log, qr/page=sites\/alpha\/bad\.md/, 'the unreadable current page is logged' );
    my ( undef, undef, @fix ) = with_log( sub { form_bind_refusal( 'sites/alpha/bad.md', "---\ntitle: fixed\n---\n", @alpha ) } );
    is( scalar @fix, 0, 'and a fix of the page that binds no form is written' );
};

subtest 'page_form_or_none: the processor\'s reading, or none when it dies' => sub {
    my ( $err, $log, $f ) = with_log( sub { page_form_or_none( "---\nform: leads\n---\n", 'x.md' ) } );
    is( $f,   'leads', 'a readable page binds its form' );
    is( $log, '',      'and logs nothing' );
    open my $fh, '<:utf8', "$d/sites/alpha/bad.md" or die $!;
    my $t = do { local $/; <$fh> };
    my ( $err2, $log2, $g ) = with_log( sub { page_form_or_none( $t, 'sites/alpha/bad.md' ) } );
    is( $err2, '',    'the page read as the processor reads it: no death' );
    is( $g,    undef, 'binds nothing' );
    like( $log2, qr/binds no form/, 'logged' );
};

done_testing();
