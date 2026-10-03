#!/usr/bin/perl
# SM938 D2: WHERE A FORM'S SUBMISSION NOTICE GOES, AND IF NOT, WHAT SAYS NO.
#
# Whether a submission reaches XMPP is decided in three places - the form's
# `notify:`, the site's notify.conf (`emit.submission`, `route.submission`), and
# the extension plus its account - and only the last had any interface. An
# operator could neither confirm from the manager that a form announces itself
# nor diagnose it when it did not.
#
# WHAT THIS PINS:
#   - each of the deciding places, and that the report names the FIRST no in the
#     order delivery meets them (a later reason sends somebody to fix something
#     that is not the cause);
#   - THE REPORT AGREES WITH DELIVERY. Each case below also runs a real notify()
#     through the XMPP seam and checks the report's `reaches_xmpp` against what
#     was actually sent. A report written from a description of the checks would
#     drift from them; one that calls them cannot, and this is where that is shown;
#   - `notify:` is parsed once, and the handler uses the same parse;
#   - a page load does not write warnings to the log.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir repo_root);

use Lazysite::Notify ();

my $root = site_tempdir();
my $lz   = "$root/lazysite";
make_path("$lz/logs");

sub write_file {
    my ( $f, $c ) = @_;
    open my $fh, '>', $f or die "$f: $!";
    print {$fh} $c;
    close $fh;
}
sub conf {
    my ($xmpp_on) = @_;
    write_file( "$lz/lazysite.conf",
        "site_name: T\n" . ( $xmpp_on ? "extensions:\n  - plugins/notify-xmpp.pl\n" : '' ) );
}
sub xmpp_account { write_file( "$lz/notify-xmpp.conf", $_[0] ) }
sub notify_conf  { write_file( "$lz/notify.conf", $_[0] ) }

my @SENT;
{
    no warnings 'redefine';
    $Lazysite::Notify::XMPP_SENDER = sub { push @SENT, $_[1]; 1 };
}

# Run the report AND a real delivery, and return both so each case can check
# they agree.
sub both {
    my ($mode) = @_;
    my $r = Lazysite::Notify::route_report( $root, 'submission', $mode );
    @SENT = ();
    if ( ( $mode // 'on' ) ne 'off' ) {    # the handler returns before notify() on off
        Lazysite::Notify::notify( $root,
            { type => 'submission', message => 'New form submission: t', target => 't' } );
    }
    return ( $r, scalar @SENT );
}
sub why_for {
    my ( $r, $ep ) = @_;
    my ($w) = grep { $_->{endpoint} eq $ep } @{ $r->{withheld} || [] };
    return $w ? $w->{why} : '';
}

subtest 'everything configured: bell and xmpp, and xmpp is really sent' => sub {
    conf(1);
    xmpp_account("jid: a\@b\npassword: x\nto: c\@d\n");
    unlink "$lz/notify.conf";
    my ( $r, $sent ) = both('on');
    is_deeply( $r->{reaches}, [qw(bell xmpp)], 'reaches bell and xmpp' );
    is( $sent, 1, 'and delivery really sent one xmpp message' );
    is( $r->{reaches_xmpp}, 1, 'the report and delivery agree' );
};

subtest "the form's own notify: off silences everything" => sub {
    my ( $r, $sent ) = both('off');
    is_deeply( $r->{reaches}, [], 'reaches nothing' );
    like( why_for( $r, 'all' ), qr/notify: off/, "and says it is the form's own setting" );
    is( $r->{mode}, 'off', 'reporting the mode' );
};

subtest 'notify.conf emit.submission: off silences the type site-wide' => sub {
    notify_conf("emit.submission: off\n");
    my ( $r, $sent ) = both('on');
    is_deeply( $r->{reaches}, [], 'reaches nothing - not even the bell' );
    like( why_for( $r, 'all' ), qr/emit\.submission: off/, 'naming the key' );
    is( $sent, 0, 'and delivery sent nothing, as the report said' );
};

subtest 'a route without xmpp withholds xmpp, and says the route is why' => sub {
    notify_conf("route.submission: bell\n");
    my ( $r, $sent ) = both('on');
    is_deeply( $r->{reaches}, ['bell'], 'reaches the bell only' );
    like( why_for( $r, 'xmpp' ), qr/routes submission to bell - xmpp is not in it/,
        'the route is named as the reason' )
        or diag( 'Here the extension is on and configured - the classic case '
            . 'where an operator checks the account, finds it fine, and has no '
            . 'way to see that the route is what drops it.' );
    is( $sent, 0, 'and delivery sent nothing to xmpp' );
};

subtest 'the extension off withholds xmpp, before its config is consulted' => sub {
    unlink "$lz/notify.conf";
    conf(0);
    my ( $r, $sent ) = both('on');
    like( why_for( $r, 'xmpp' ), qr/switched off/, 'the extension is named' );
    is( $sent, 0, 'and nothing was sent' );
};

subtest 'an incomplete account withholds xmpp, naming what is missing' => sub {
    conf(1);
    xmpp_account("jid: a\@b\n");
    my ( $r, $sent ) = both('on');
    like( why_for( $r, 'xmpp' ), qr/incomplete: no password, to/, 'naming the keys' );
    is( $sent, 0, 'and nothing was sent' );
    is( $r->{reaches_xmpp}, 0, 'the report and delivery agree' );
};

subtest 'opening the page does not write to the log' => sub {
    # The checks are shared with delivery, which logs when a submission is
    # dropped. A report that logged too would put a WARN in the engine log every
    # time an operator opened the Handlers page.
    my $logged = 0;
    no warnings 'redefine';
    local *Lazysite::Notify::log_event = sub { $logged++ };
    Lazysite::Notify::route_report( $root, 'submission', 'on' );
    is( $logged, 0, 'the report logged nothing' );
    my @r = Lazysite::Notify::_xmpp_conf_or_why($root);
    cmp_ok( $logged, '>', 0, 'while the delivery-path check still does' )
        or diag( 'Silencing the report must not silence delivery.' );
};

subtest 'notify: is parsed once, and the handler uses it' => sub {
    is( ( Lazysite::Notify::form_notify_mode("notify: full\n") )[0], 'full', 'full' );
    is( ( Lazysite::Notify::form_notify_mode("notify: no\n") )[0],   'off',  'no -> off' );
    is( ( Lazysite::Notify::form_notify_mode("targets: []\n") )[0],  'on',   'absent -> on' );
    my ( $m, $bad ) = Lazysite::Notify::form_notify_mode("notify: fll\n");
    is( $m,   'on',  'an unrecognised value stays on' );
    is( $bad, 'fll', 'and is returned so the caller can name it' );

    my $src = do {
        open my $f, '<', repo_root() . '/plugins/form-handler.pl' or die;
        local $/;
        <$f>;
    };
    like( $src, qr/Lazysite::Notify::form_notify_mode\(/,
        'the form handler calls the shared parse' );
    unlike( $src, qr/elsif \( \$v =~ \/\^full\$\/ \)/,
        'and no longer carries its own copy' );
};

done_testing();
