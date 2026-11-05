#!/usr/bin/perl
# SM472: an extension that cannot run is not enabled.
#
# ADR 0009 has an extension DECLARE the modules it needs, and the SBOM gate reads
# that list so nothing ships undeclared. Nothing read it at the one moment it
# answers a question an operator actually has: can this work HERE?
#
# FOUND THE EXPENSIVE WAY. The data extension enabled cleanly on a host without
# YAML::PP, listed its empty set of tables happily, and answered HTTP 500 to
# every attempt to declare one - because the parser is only reached once there
# is something to parse. The field bisected five variations of the request
# before concluding the write path was broken. Every signal was honest and none
# of them said the word "YAML::PP".
#
# REFUSED RATHER THAN WARNED: the alternative is an extension that is on and does
# not work, which is the state that produced those 500s.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Extensions ();

my $base = tempdir( CLEANUP => 1 );
my $doc  = "$base/public_html";
make_path( "$doc/lazysite", "$base/extensions" );
open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

# An extension whose declaration is the only thing under test.
sub extension {
    my ( $name, @deps ) = @_;
    my $list = join ', ', map {"'$_'"} @deps;
    open my $fh, '>', "$base/extensions/$name.pl" or die $!;
    print {$fh} <<"P";
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ id => '$name', name => '$name', version => '1',
    config_file => '', config_schema => [], actions => [],
    contract => 1, owns => { deps => [ $list ] } });
P
    close $fh;
    chmod 0755, "$base/extensions/$name.pl";
    return "extensions/$name.pl";
}

local $Lazysite::Manager::Extensions::DOCROOT = $doc;

subtest 'an extension whose modules are present enables' => sub {
    my $p = extension( 'fine', 'JSON::PP' );    # core, always there
    my $r = Lazysite::Manager::Extensions::action_extension_enable($p);
    ok( $r->{ok}, 'it enables' ) or diag( $r->{error} // '' );
    ok( Lazysite::Manager::Extensions::extension_enabled($p), 'and is on' );
};

subtest 'an extension whose modules are ABSENT is refused, and told why' => sub {
    my $p = extension( 'needy', 'No::Such::Module::Here' );
    my $r = Lazysite::Manager::Extensions::action_extension_enable($p);

    ok( !$r->{ok}, 'it is refused' )
        or diag( 'Enabling it would produce an extension that is on and does not '
            . 'work - the state that produced the 500s.' );
    is( $r->{kind}, 'missing_deps', 'with a kind a surface can branch on' );
    like( $r->{error}, qr/No::Such::Module::Here/, 'NAMING the module' )
        or diag( 'The whole finding was that nothing anywhere said the '
            . 'module name.' );
    like( $r->{error}, qr/Debian: lib/, 'and a package that provides it' )
        or diag( 'A refusal without a next step is a dead end.' );

    ok( !Lazysite::Manager::Extensions::extension_enabled($p),
        'and it is left OFF' )
        or diag( 'Refusing but enabling anyway would be the worst of both.' );
};

subtest 'an extension that declares nothing is unaffected' => sub {
    # Every existing extension declares no deps, and none of them should change
    # behaviour because this check was added.
    my $p = extension('quiet');
    my $r = Lazysite::Manager::Extensions::action_extension_enable($p);
    ok( $r->{ok}, 'it enables as before' ) or diag( $r->{error} // '' );
};

subtest 'the declaration is the source, not a list kept here' => sub {
    # A list in the manager would be a second opinion about the same fact and
    # would go stale the first time an extension gained a dependency.
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Extensions.pm"
            or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $src =~ /sub _missing_deps \{(.*?)\n\}/s;
    ok( defined $fn, '_missing_deps is present' );
    like( $fn, qr/owns\}\{deps\}/, 'it reads the extension\'s own declaration' );
    unlike( $fn, qr/YAML::PP|DBD::SQLite/,
        'and names no module of its own' )
        or diag( 'Hard-coding one extension\'s dependencies here is how the '
            . 'second extension gets no check at all.' );
};

done_testing();
