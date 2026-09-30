#!/usr/bin/perl
# SM925 X3: _xmpp_conf returned undef for FOUR distinct causes and said nothing
# about any of them - the extension off, no conf file, a conf that will not open,
# and a conf missing a required key. An operator spent an afternoon over four
# submissions on a site where the answer was one of them, and the code knew which.
#
# Only the first is a deliberate state. The other three are faults, and a fault
# that returns the same value as a deliberate state is the four-state defect SM906,
# SM907 and SM917 removed from the stores - arriving on the notification path.
#
# Every case asserts BOTH that nothing was sent AND which sentence came out, because
# "returns undef" was never the bug: saying nothing was.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);

require Lazysite::Notify;

# A site with the extension enabled unless told otherwise, and an optional
# notify-xmpp.conf body.
sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/logs");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n";
    print {$cf} "extensions:\n  - plugins/notify-xmpp.pl\n" unless $o{disabled};
    close $cf;
    if ( defined $o{conf} ) {
        open my $xf, '>', "$d/lazysite/notify-xmpp.conf" or die $!;
        print {$xf} $o{conf};
        close $xf;
    }
    return $d;
}

# _xmpp_conf is private; call it and capture what it said on STDERR.
sub probe {
    my ($d) = @_;
    my ( $err, $got );
    {
        local *STDERR;
        open STDERR, '>', \$err or die $!;
        $got = Lazysite::Notify::_xmpp_conf($d);
    }
    return ( $got, $err // '' );
}

subtest 'the extension is OFF - a deliberate state, and silent' => sub {
    my ( $got, $err ) = probe( site( disabled => 1, conf => "jid: a\@b\npassword: p\nto: c\@d\n" ) );
    ok( !$got, 'no config is returned' );
    is( $err, '', 'and nothing is logged - this is a choice, not a fault' );
};

subtest 'enabled and NEVER CONFIGURED - says so, and names the file' => sub {
    my ( $got, $err ) = probe( site() );    # no notify-xmpp.conf at all
    ok( !$got, 'no config is returned' );
    like( $err, qr/enabled and not configured/, 'the state is named' );
    like( $err, qr/nothing is sent/, 'and the consequence is named' );
    like( $err, qr/notify-xmpp\.conf/, 'and the file is named' );
};

subtest 'enabled and the conf WILL NOT OPEN - a different sentence' => sub {
    my $d = site( conf => "jid: a\@b\npassword: p\nto: c\@d\n" );
  SKIP: {
        skip 'running as root: chmod 000 would not deny this process', 4 if $> == 0;
        chmod 0000, "$d/lazysite/notify-xmpp.conf" or die "chmod: $!";
        my ( $got, $err ) = probe($d);
        ok( !$got, 'no config is returned' );
        like( $err, qr/cannot read/, 'reported as unreadable' );
        like( $err, qr/xmpp client config/, 'naming what it is' );
        unlike( $err, qr/not configured/,
            'and NOT confused with the never-configured case - that is the whole point' );
        chmod 0644, "$d/lazysite/notify-xmpp.conf";
    }
};

subtest 'enabled and INCOMPLETE - says which key is missing' => sub {
    my ( $got, $err ) = probe( site( conf => "jid: a\@b\nto: c\@d\n" ) );    # no password
    ok( !$got, 'no config is returned' );
    like( $err, qr/without a value it cannot work without/, 'the state is named' );
    like( $err, qr/missing=password/, 'and the missing key is named, not just the fact' );
};

subtest 'enabled and complete - returns the config and says nothing' => sub {
    my ( $got, $err ) = probe( site( conf => "jid: a\@b\npassword: p\nto: c\@d\n" ) );
    ok( $got, 'the config is returned' );
    is( $got->{jid}, 'a@b', 'with the values read' );
    ok( length( $got->{nick} // '' ), 'and the nick defaulted from the site name' );
    is( $err, '', 'the healthy path is silent' );
};

done_testing();
