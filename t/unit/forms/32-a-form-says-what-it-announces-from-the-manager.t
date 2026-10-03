#!/usr/bin/perl
# SM938 D4 / R17: A FORM'S notify: IS SET FROM THE MANAGER.
#
# D2 made the Handlers page say where a form's submission notice goes and what
# stops it. The form's own `notify:` was the one deciding place that was the
# form's to change, and the only way to change it was to edit the conf as text
# over WebDAV. form-notify-save (MCP: set_form_notify) writes it.
#
# WHAT THIS PINS:
#   - the line is written into the form's own conf - the text stays the source
#     of truth (R17), and the parse delivery uses reads back what was written;
#   - a rewrite keeps what it did not come to change (the bindings, other keys)
#     and leaves exactly ONE notify: line, because the reader takes the first;
#   - only off / on / full are accepted - the reader treats anything else as
#     `on`, so writing it would look like it took and change nothing;
#   - the reply carries D2's report, computed AFTER the write;
#   - the Handlers page offers it, and writes it only when it was changed.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir repo_root);
use Lazysite::Handlers ();
use Lazysite::Notify   ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

sub a_site {
    my ($conf) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/forms");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n  - id: jsonl\n    type: file\n    path: lazysite/forms/submissions\n" );
    spit( "$d/lazysite/forms/contact.conf",
        $conf // "targets:\n  - handler: jsonl\nrate_limit: 5\n" );
    $Lazysite::Handlers::DOCROOT = $d;
    return $d;
}
sub conf_of { slurp("$_[0]/lazysite/forms/contact.conf") // '' }
sub save    { Lazysite::Handlers::action_form_notify_save(@_) }

subtest 'off is written into the form\'s own conf, and delivery reads it back' => sub {
    my $d = a_site();
    my $r = save( 'contact', 'off' );
    ok( $r->{ok}, 'accepted' ) or diag explain $r;
    my $c = conf_of($d);
    like( $c, qr/^notify: off$/m, 'the line is in the conf' );
    is( ( Lazysite::Notify::form_notify_mode($c) )[0], 'off',
        'and the parse delivery uses reads it as off' );
};

subtest 'a rewrite keeps what it did not come to change' => sub {
    my $d = a_site();
    save( 'contact', 'full' );
    my $c = conf_of($d);
    like( $c, qr/\Atargets:\n  - handler: jsonl\n/, 'the binding is still first' );
    like( $c, qr/^rate_limit: 5$/m, 'another key survives' );
};

subtest 'exactly one notify: line after a change' => sub {
    my $d = a_site("targets:\n  - handler: jsonl\nnotify: full\nnotify: on\n");
    save( 'contact', 'off' );
    my @n = conf_of($d) =~ /^notify\s*:/mg;
    is( scalar @n, 1, 'one line' )
        or diag( 'The reader takes the FIRST notify: line, so a stale one left '
            . 'above the new one would be the one that decides.' );
    is( ( Lazysite::Notify::form_notify_mode( conf_of($d) ) )[0], 'off', 'and it is the new value' );
};

subtest 'only off, on and full' => sub {
    my $d      = a_site();
    my $before = conf_of($d);
    for my $bad ( 'fll', '', 'yes', undef ) {
        my $r = save( 'contact', $bad );
        ok( !$r->{ok}, 'refused: ' . ( defined $bad ? "'$bad'" : 'absent' ) );
        is( $r->{field}, 'notify', 'naming the field' );
    }
    is( conf_of($d), $before, 'and nothing was written' );
    ok( save( 'contact', 'FULL' )->{ok}, 'the case of a valid value does not matter' );
    ok( !save( 'handlers', 'off' )->{ok}, 'handlers.conf is not a form' );
};

subtest 'the reply says where a notice now goes, read after the write' => sub {
    my $d = a_site();
    my $r = save( 'contact', 'off' );
    is_deeply( $r->{announces}{reaches}, [], 'off: it reaches nothing' );
    like( $r->{announces}{withheld}[0]{why}, qr/notify: off/, 'and says it is this form' );
    $r = save( 'contact', 'on' );
    is_deeply( $r->{announces}{reaches}, ['bell'], 'on: the bell (no xmpp on this site)' );
    like( join( ' ', map { $_->{why} } @{ $r->{announces}{withheld} } ),
        qr/switched off/, 'and xmpp is withheld by the extension, named' );
};

subtest 'the Handlers page offers it, and writes it only when changed' => sub {
    my $src = slurp( repo_root() . '/starter/manager/handlers.md' ) // '';
    like( $src, qr/function notifyControl\(n\)/, 'a notify control on the form' );
    like( $src, qr/notifyDetail\(form\)\s*\+ notifyControl\(form\)/,
        'shown in the expanded form, under where it says what is announced' );
    like( $src, qr/sel\.value === sel\.getAttribute\('data-was'\)/,
        'and saving the handlers does not rewrite an untouched notify: line' );
    like( $src, qr/post\('form-notify-save'/, 'through the action' );
};

done_testing();
