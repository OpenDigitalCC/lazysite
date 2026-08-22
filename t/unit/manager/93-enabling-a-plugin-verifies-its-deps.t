#!/usr/bin/perl
# SM472: a plugin that cannot run is not enabled.
#
# ADR 0009 has a plugin DECLARE the modules it needs, and the SBOM gate reads
# that list so nothing ships undeclared. Nothing read it at the one moment it
# answers a question an operator actually has: can this work HERE?
#
# FOUND THE EXPENSIVE WAY. The data plugin enabled cleanly on a host without
# YAML::PP, listed its empty set of tables happily, and answered HTTP 500 to
# every attempt to declare one - because the parser is only reached once there
# is something to parse. The field bisected five variations of the request
# before concluding the write path was broken. Every signal was honest and none
# of them said the word "YAML::PP".
#
# REFUSED RATHER THAN WARNED: the alternative is a plugin that is on and does
# not work, which is the state that produced those 500s.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Plugins ();

my $base = tempdir( CLEANUP => 1 );
my $doc  = "$base/public_html";
make_path( "$doc/lazysite", "$base/plugins" );
open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

# A plugin whose declaration is the only thing under test.
sub plugin {
    my ( $name, @deps ) = @_;
    my $list = join ', ', map {"'$_'"} @deps;
    open my $fh, '>', "$base/plugins/$name.pl" or die $!;
    print {$fh} <<"P";
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ id => '$name', name => '$name', version => '1',
    config_file => '', config_schema => [], actions => [],
    contract => 1, owns => { deps => [ $list ] } });
P
    close $fh;
    chmod 0755, "$base/plugins/$name.pl";
    return "plugins/$name.pl";
}

local $Lazysite::Manager::Plugins::DOCROOT = $doc;

subtest 'a plugin whose modules are present enables' => sub {
    my $p = plugin( 'fine', 'JSON::PP' );    # core, always there
    my $r = Lazysite::Manager::Plugins::action_plugin_enable($p);
    ok( $r->{ok}, 'it enables' ) or diag( $r->{error} // '' );
    ok( Lazysite::Manager::Plugins::plugin_enabled($p), 'and is on' );
};

subtest 'a plugin whose modules are ABSENT is refused, and told why' => sub {
    my $p = plugin( 'needy', 'No::Such::Module::Here' );
    my $r = Lazysite::Manager::Plugins::action_plugin_enable($p);

    ok( !$r->{ok}, 'it is refused' )
        or diag( 'Enabling it would produce a plugin that is on and does not '
            . 'work - the state that produced the 500s.' );
    is( $r->{kind}, 'missing_deps', 'with a kind a surface can branch on' );
    like( $r->{error}, qr/No::Such::Module::Here/, 'NAMING the module' )
        or diag( 'The whole finding was that nothing anywhere said the '
            . 'module name.' );
    like( $r->{error}, qr/Debian: lib/, 'and a package that provides it' )
        or diag( 'A refusal without a next step is a dead end.' );

    ok( !Lazysite::Manager::Plugins::plugin_enabled($p),
        'and it is left OFF' )
        or diag( 'Refusing but enabling anyway would be the worst of both.' );
};

subtest 'a plugin that declares nothing is unaffected' => sub {
    # Every existing plugin declares no deps, and none of them should change
    # behaviour because this check was added.
    my $p = plugin('quiet');
    my $r = Lazysite::Manager::Plugins::action_plugin_enable($p);
    ok( $r->{ok}, 'it enables as before' ) or diag( $r->{error} // '' );
};

subtest 'the declaration is the source, not a list kept here' => sub {
    # A list in the manager would be a second opinion about the same fact and
    # would go stale the first time a plugin gained a dependency.
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Plugins.pm"
            or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $src =~ /sub _missing_deps \{(.*?)\n\}/s;
    ok( defined $fn, '_missing_deps is present' );
    like( $fn, qr/owns\}\{deps\}/, 'it reads the plugin\'s own declaration' );
    unlike( $fn, qr/YAML::PP|DBD::SQLite/,
        'and names no module of its own' )
        or diag( 'Hard-coding one plugin\'s dependencies here is how the '
            . 'second plugin gets no check at all.' );
};

done_testing();
