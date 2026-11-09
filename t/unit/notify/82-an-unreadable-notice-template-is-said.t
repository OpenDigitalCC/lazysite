#!/usr/bin/perl
# Ruling 206 (item 21 of the 0.16.9 fault survey): AN UNREADABLE NOTICE
# TEMPLATE IS SAID, NOT SILENTLY REPLACED.
#
# Notify::_template skipped a site template under lazysite/notify-templates/
# that exists and will not open, and the built-in was used in silence - the
# operator's own wording gone with nothing to say why. Now it WARNs naming the
# file and `lazysite check`; the built-in still carries the notice, so the
# notice is not lost. An absent template is the site not overriding: quiet.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper       qw(site_tempdir);
use Lazysite::Notify ();

plan skip_all => 'running as root: a mode cannot be made unreadable' if $> == 0;

my $d = site_tempdir();
make_path("$d/lazysite/notify-templates");

sub template {
    my $err = '';
    my @r;
    {
        local *STDERR;
        open STDERR, '>', \$err or die $!;
        @r = Lazysite::Notify::_template( $d, 'default', 'xmpp', 0 );
        close STDERR;
    }
    return ( $err, @r );
}

subtest 'absent: the built-in, quietly' => sub {
    my ( $err, $body, $from_file ) = template();
    ok( !$from_file, 'the built-in' );
    is( $err, '', 'nothing logged' );
};

subtest 'unreadable: the built-in, and a WARN naming the file' => sub {
    my $t = "$d/lazysite/notify-templates/default.xmpp.tt";
    open my $w, '>', $t or die $!;
    print {$w} "SITE: [% message %]\n";
    close $w;
    chmod 0000, $t;
    my ( $err, $body, $from_file ) = template();
    chmod 0644, $t;
    ok( !$from_file, 'the built-in carries the notice' );
    like( $err, qr/cannot read the notice template lazysite\/notify-templates\/default\.xmpp\.tt/,
        'the log names the file' );
    like( $err, qr/lazysite check --docroot names it/, 'and the check' );

    ( $err, $body, $from_file ) = template();
    ok( $from_file, 'once readable, the site template is used' );
    like( $body, qr/\ASITE: /, 'its own wording' );
};

done_testing();
