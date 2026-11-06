#!/usr/bin/perl
# SM1373: extension-read answers only the keys the extension names.
#
# An extension whose config_file is lazysite/lazysite.conf (bad-url-blocker, log)
# was answered EVERY key in the site's main config, not only its own: a read of
# bad-url-blocker's settings returned the site's other settings beside them. Only
# the extension's own password fields were dropped. The values are now the keys
# its config_schema or config_keys names, whatever its config file - a foreign key
# in the file is not answered, and a password field still is not.
#
# The descriptors are the shipped extensions' own (--describe), so the test
# follows what they declare; the config files are a fixture docroot.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                    qw(repo_root site_tempdir);
use Lazysite::Manager::Extensions ();

my $root = repo_root();
plan skip_all => 'no extensions/ in this tree' unless -d "$root/extensions";

my $d = site_tempdir();
make_path("$d/lazysite/forms");

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

spit( "$d/lazysite/lazysite.conf", join "\n",
    'site_name: Example', 'manager_groups: sysops', 'odoo_password: FOREIGN-SECRET',
    'bad_url_block: 1',   'bad_url_threshold: 20',  'log_level: info', '' );
spit( "$d/lazysite/forms/smtp.conf", join "\n",
    'method: smtp', 'host: mail.example.org', 'password: SMTP-SECRET',
    'not_in_schema: OWN-FILE-STRAY', '' );

$Lazysite::Manager::Extensions::DOCROOT = $d;
no warnings qw(redefine once);
my %script = (
    'bad-url-blocker' => "$root/extensions/bad-url-blocker.pl",
    logging           => "$root/extensions/log.pl",
    'form-smtp'       => "$root/extensions/form-smtp.pl",
);
local *Lazysite::Manager::Extensions::_resolve_extension_or_why = sub {
    my ($id) = @_;
    return $script{$id} ? ( $script{$id}, '' ) : ( undef, "no $id" );
};
use warnings qw(redefine once);

sub read_values {
    my ($id) = @_;
    my $r = Lazysite::Manager::Extensions::action_extension_read( $id, undef );
    ok( $r->{ok}, "$id is read" ) or diag explain $r;
    return $r->{values} // {};
}

subtest 'an extension configured in lazysite.conf gets only its own keys' => sub {
    my $v = read_values('bad-url-blocker');
    is( $v->{bad_url_block},     '1',  'its own key is answered' );
    is( $v->{bad_url_threshold}, '20', '  and its other one' );
    for my $k (qw(site_name manager_groups odoo_password log_level)) {
        ok( !exists $v->{$k}, "  a foreign key ($k) is not" );
    }
    unlike( join( ' ', values %$v ), qr/FOREIGN-SECRET/, '  no foreign value reaches the answer' );

    my $l = read_values('logging');
    is( $l->{log_level}, 'info', 'the other lazysite.conf extension gets its own key' );
    ok( !exists $l->{bad_url_block}, '  and not its neighbour\'s' );
    ok( !exists $l->{site_name},     '  nor the site\'s' );
};

subtest 'an extension with its own file gets only the keys it names' => sub {
    my $v = read_values('form-smtp');
    is( $v->{host},   'mail.example.org', 'a schema key is answered' );
    is( $v->{method}, 'smtp',             '  and another' );
    ok( !exists $v->{password},      '  the password field is still dropped' );
    ok( !exists $v->{not_in_schema}, '  and a key its schema does not name is not answered' );
};

done_testing();
