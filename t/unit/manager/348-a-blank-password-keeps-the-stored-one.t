#!/usr/bin/perl
# SM1108 (0.15.7 test plan, "Found while getting mail to send", U5): "A blank
# password clears the stored SMTP password. The Form SMTP field says 'Leave blank
# to keep the current one'. An extension-save with password: '' answered
# changed: [..., 'password'], and the next send failed 'SMTP auth failed'."
#
# The manager never sends a stored password back (it is not shown again), so a
# form that is saved with the field untouched posts it empty. A blank value for a
# `type: password` field is therefore "unchanged" - for every extension, not only
# this one - and it is not in `changed`. A real new value still lands.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);
use Lazysite::Manager::Plugins ();

my $root   = repo_root();
my $parent = site_tempdir();    # lint 118: not a bare tempdir
my $d      = "$parent/public_html";
make_path( "$d/lazysite/forms", "$parent/plugins" );
copy( "$root/plugins/form-smtp.pl", "$parent/plugins/form-smtp.pl" ) or die $!;
chmod 0755, "$parent/plugins/form-smtp.pl";
local $ENV{PERL5LIB} = "$root/lib" . ( $ENV{PERL5LIB} ? ":$ENV{PERL5LIB}" : '' );

my $conf = "$d/lazysite/forms/smtp.conf";
sub reset_conf {
    open my $c, '>', $conf or die $!;
    print {$c} "method: smtp\nhost: mail.example.net\nauth: true\nusername: ada\npassword: s3cret\n";
    close $c;
}
sub conf { open my $h, '<', $conf or return ''; local $/; return <$h> }
$Lazysite::Manager::Plugins::DOCROOT = $d;
sub save { return Lazysite::Manager::Plugins::action_plugin_save( undef, 'plugins/form-smtp.pl', {@_} ) }

# The canary: a real new password lands, and is reported as changed.
reset_conf();
{
    my $r = save( password => 'newer' );
    ok( $r->{ok}, 'a new password saves' ) or diag( $r->{error} // '' );
    like( conf(), qr/^password: newer$/m, '...and is written' );
    ok( ( grep { $_ eq 'password' } @{ $r->{changed} || [] } ), '...and is reported changed' );
}

# The finding, for an empty value and for one that is only whitespace.
for my $blank ( '', '   ', "\t" ) {
    reset_conf();
    my $r = save( host => 'mail2.example.net', password => $blank );
    ok( $r->{ok}, 'a save with a blank password succeeds' ) or diag( $r->{error} // '' );
    like( conf(), qr/^password: s3cret$/m, 'the stored password is kept' )
        or diag("smtp.conf now:\n" . conf());
    ok( !( grep { $_ eq 'password' } @{ $r->{changed} || [] } ), '...and is not in changed' )
        or diag( 'changed: ' . join( ',', @{ $r->{changed} || [] } ) );
    like( conf(), qr/^host: mail2\.example\.net$/m, '...while the other fields in the same save still land' );
}

# A blank password on a config that has none yet writes nothing for it.
{
    open my $c, '>', $conf or die $!;
    print {$c} "method: smtp\n";
    close $c;
    my $r = save( password => '' );
    ok( $r->{ok}, 'a blank password with none stored saves' );
    unlike( conf(), qr/^password:/m, '...and adds no empty password line' );
    ok( !( grep { $_ eq 'password' } @{ $r->{changed} || [] } ), '...and is not in changed' );
}

done_testing;
