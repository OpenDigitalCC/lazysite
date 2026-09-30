#!/usr/bin/perl
# SM915: the writer matched `plugins:` alone, so on a site using the name SM817
# introduced (`extensions:`) the header and all its entries fell through to the
# preserved-lines list, the rebuild emitted a SECOND list under the old spelling
# carrying only the script just added, and disable removed nothing from a list it
# could not see - and reported ok.
#
# Reproduced in tmp/sm915-repro.pl before the fix: on an `extensions:` site,
# enable gave 2 lists and disable answered ok=1 having removed nothing.
#
# Every case below runs on BOTH spellings, because a `plugins:` site worked all
# along and a test that only exercises the broken one cannot tell a fix from a
# swap of which spelling is broken.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

require Lazysite::Manager::Plugins;

# A site whose extension list is written under $header, with two entries.
sub site {
    my ( $header, @extra ) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/cache");
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: T\n";
    print {$fh} "$header:\n  - plugins/stats.pl\n  - plugins/audit.pl\n" if $header;
    print {$fh} @extra;
    print {$fh} "auth_default: none\n";
    close $fh;
    return $d;
}

sub conf {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/lazysite.conf" or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub lists {
    my ($c) = @_;
    return ( scalar( () = $c =~ /^plugins\s*:\s*$/mg ),
        scalar( () = $c =~ /^extensions\s*:\s*$/mg ) );
}

for my $header (qw(plugins extensions)) {

    subtest "enable on a `$header:` site writes ONE list, under that header" => sub {
        my $d = site($header);
        local $Lazysite::Manager::Plugins::DOCROOT = $d;
        my $r = Lazysite::Manager::Plugins::_update_plugins_conf(
            'plugins/notify-xmpp.pl', 'add' );
        ok( $r->{ok}, 'the enable is accepted' );
        my $c = conf($d);
        my ( $p, $e ) = lists($c);
        is( $p + $e, 1, 'exactly one list in the conf' );
        is( $header eq 'plugins' ? $p : $e, 1, "and it is the `$header:` one" );
        is( $header eq 'plugins' ? $e : $p, 0, 'the other spelling was not introduced' );
        like( $c, qr{^\s+-\s+plugins/notify-xmpp\.pl$}m, 'the new entry is listed' );
        like( $c, qr{^\s+-\s+plugins/stats\.pl$}m,  'and the entries already there survive' );
        like( $c, qr{^\s+-\s+plugins/audit\.pl$}m,  'both of them' );
        like( $c, qr/^auth_default: none$/m, 'the keys after the list survive' );
    };

    subtest "disable on a `$header:` site actually removes the entry" => sub {
        my $d = site($header);
        local $Lazysite::Manager::Plugins::DOCROOT = $d;
        my $r = Lazysite::Manager::Plugins::_update_plugins_conf(
            'plugins/stats.pl', 'remove' );
        ok( $r->{ok}, 'the disable is accepted' );
        my $c = conf($d);
        unlike( $c, qr{^\s+-\s+plugins/stats\.pl$}m, 'the entry is gone' );
        like( $c, qr{^\s+-\s+plugins/audit\.pl$}m, 'the other entry is not' );
        my ( $p, $e ) = lists($c);
        is( $p + $e, 1, 'still exactly one list' );
    };
}

# The state the defect produced on live sites, and the 2026-09-29 ruling: refuse,
# name the file, and change nothing. Merging would edit a list the operator did
# not ask to be edited in this call; leaving it silent is the state that was
# reported.
subtest 'a conf carrying BOTH headers is refused, by name, and left alone' => sub {
    my $d = site( 'extensions', "plugins:\n  - plugins/form-handler.pl\n" );
    local $Lazysite::Manager::Plugins::DOCROOT = $d;
    my $before = conf($d);

    for my $op (qw(add remove)) {
        my $r = Lazysite::Manager::Plugins::_update_plugins_conf(
            ( $op eq 'add' ? 'plugins/notify-xmpp.pl' : 'plugins/stats.pl' ), $op );
        ok( !$r->{ok}, "$op is refused" );
        like( $r->{error}, qr/\Qlazysite.conf\E/,
            "$op names the file, so the operator knows which one to fix" );
        like( $r->{error}, qr/both an `extensions:` and a `plugins:` list/,
            "$op says what is wrong with it" );
        is( conf($d), $before, "$op wrote nothing" );
    }
};

# A site with no list at all gets the CURRENT name, not the retired one - there is
# no header it "already uses", and reviving `plugins:` on a site that never had it
# would spread the old spelling.
subtest 'a site with no list at all gets `extensions:`' => sub {
    my $d = site(undef);
    local $Lazysite::Manager::Plugins::DOCROOT = $d;
    my $r = Lazysite::Manager::Plugins::_update_plugins_conf( 'plugins/stats.pl', 'add' );
    ok( $r->{ok}, 'the enable is accepted' );
    my ( $p, $e ) = lists( conf($d) );
    is( $e, 1, 'the new list is written as `extensions:`' );
    is( $p, 0, 'and not as `plugins:`' );
};

done_testing();
