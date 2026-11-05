#!/usr/bin/perl
# SM915: the writer matched the old list header alone, so on a site using the
# name SM817 introduced (`extensions:`) the header and all its entries fell
# through to the preserved-lines list, the rebuild emitted a SECOND list carrying
# only the script just added, and disable removed nothing from a list it could
# not see - and reported ok.
#
# SM1142 (R3): `extensions:` is now the one name - the upgrade rewrites the old
# one - so the writer reads and writes that list and no other. A list an operator
# writes back under the old header afterwards is not a list to the writer (nor
# to any reader); it is left as the operator wrote it, and `lazysite check` names
# the line (t/tools/... the check's own test).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

require Lazysite::Manager::Extensions;

# A site whose extension list is written under $header, with two entries.
sub site {
    my ( $header, @extra ) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/cache");
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: T\n";
    print {$fh} "$header:\n  - extensions/stats.pl\n  - extensions/audit.pl\n" if $header;
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

sub lists { my ($c) = @_; return scalar( () = $c =~ /^extensions\s*:\s*$/mg ) }

subtest 'enable writes ONE list' => sub {
    my $d = site('extensions');
    local $Lazysite::Manager::Extensions::DOCROOT = $d;
    my $r = Lazysite::Manager::Extensions::_update_extensions_conf( 'extensions/notify-xmpp.pl', 'add' );
    ok( $r->{ok}, 'the enable is accepted' );
    my $c = conf($d);
    is( lists($c), 1, 'exactly one list in the conf' );
    like( $c, qr{^\s+-\s+extensions/notify-xmpp\.pl$}m, 'the new entry is listed' );
    like( $c, qr{^\s+-\s+extensions/stats\.pl$}m,  'and the entries already there survive' );
    like( $c, qr{^\s+-\s+extensions/audit\.pl$}m,  'both of them' );
    like( $c, qr/^auth_default: none$/m, 'the keys after the list survive' );
};

subtest 'disable actually removes the entry' => sub {
    my $d = site('extensions');
    local $Lazysite::Manager::Extensions::DOCROOT = $d;
    my $r = Lazysite::Manager::Extensions::_update_extensions_conf( 'extensions/stats.pl', 'remove' );
    ok( $r->{ok}, 'the disable is accepted' );
    my $c = conf($d);
    unlike( $c, qr{^\s+-\s+extensions/stats\.pl$}m, 'the entry is gone' );
    like( $c, qr{^\s+-\s+extensions/audit\.pl$}m, 'the other entry is not' );
    is( lists($c), 1, 'still exactly one list' );
};

subtest 'a site with no list at all gets `extensions:`' => sub {
    my $d = site(undef);
    local $Lazysite::Manager::Extensions::DOCROOT = $d;
    my $r = Lazysite::Manager::Extensions::_update_extensions_conf( 'extensions/stats.pl', 'add' );
    ok( $r->{ok}, 'the enable is accepted' );
    is( lists( conf($d) ), 1, 'the new list is written as `extensions:`' );
};

# old-name: begin (SM1142, the writer is shown to leave the old header alone)
subtest 'a list under the old header is not the writer\'s, and is left as written' => sub {
    my $d = site('plugins');
    local $Lazysite::Manager::Extensions::DOCROOT = $d;
    my $r = Lazysite::Manager::Extensions::_update_extensions_conf( 'extensions/notify-xmpp.pl', 'add' );
    ok( $r->{ok}, 'the enable is accepted' );
    my $c = conf($d);
    like( $c, qr/^plugins:\n  - extensions\/stats\.pl\n  - extensions\/audit\.pl\n/m,
        'the old block is untouched' );
    like( $c, qr/^extensions:\n  - extensions\/notify-xmpp\.pl$/m,
        'and the enabled extension is listed under the one name' );
    ok( !Lazysite::Manager::Extensions::extension_enabled('extensions/stats.pl'),
        'an entry under the old header reads as off' );
};
# old-name: end

done_testing();
