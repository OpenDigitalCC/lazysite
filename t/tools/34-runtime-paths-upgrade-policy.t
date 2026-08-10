#!/usr/bin/perl
# SM246 (deliverable 3): create_runtime_paths honours the declared
# fresh-versus-upgrade policy.
#
# The policy used to be implicit in one branch - `chmod $mode, $path if
# $install_mode eq 'fresh'` - which meant the installer could not repair a
# directory whose mode was wrong on an upgrade, and only `check --fix` could.
# Two tools, two policies, on the same paths.
#
# It is now per path, because both answers are legitimate and the fault was being
# unable to say which one applied:
#
#   repair  the engine owns it absolutely. These are the directories the CGI MUST
#           write; an operator "tightening" lazysite/cache breaks their own site
#           and the failure reads as a rendering fault, not a permission one.
#   leave   set on creation, never touched. ../plugins is EXECUTED, not written.
#
# The installer is driven from the manifest, so this exercises the function
# directly with model-shaped input rather than running a whole install.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd        ();
use FindBin;

my $INSTALL = "$FindBin::Bin/../../install.pl";
ok( -f $INSTALL, 'install.pl located' );

# Load the installer's subs without running its main flow. It is a script, so
# this is the LOAD_ONLY-style trick the suite uses elsewhere: read it, strip the
# shebang, and eval the sub definitions we need.
my $src = do {
    open my $fh, '<', $INSTALL or die $!;
    local $/;
    <$fh>;
};
my ($fn) = $src =~ /(sub create_runtime_paths\b.*?\n\})/s;
ok( defined $fn, 'create_runtime_paths body extracted' );

my ($resolver) = $src =~ /(sub resolve_placeholders\b.*?\n\})/s;
ok( defined $resolver, 'resolve_placeholders extracted' );

# SM246: create_runtime_paths now creates a path's PARENTS through the shared
# directory model rather than letting make_path give every level one mode, so
# the helper and its dirname import come along too. With no model loaded here
# (%INSTALL_DIR_MODE empty) make_declared_path falls back to plain make_path,
# which is the older-payload behaviour and is what this test is about - the
# declared modes on intermediates are t/tools/35's subject.
my ($mkdirs)   = $src =~ /(sub make_declared_path\b.*?\n\})/s;
my ($symguard) = $src =~ /(sub _refuse_symlink\b.*?\n\})/s;
my ($symtest)  = $src =~ /(sub _is_symlink\b.*?\n\})/s;
ok( defined $symguard && defined $symtest, 'the SM268 symlink guards extracted' );
ok( defined $mkdirs,                       'make_declared_path extracted' );

{
    no warnings 'redefine';
    eval "use File::Path qw(make_path); use File::Basename qw(dirname);"
        . " our %INSTALL_DIR_MODE; our \$INSTALL_DOCROOT;"
        . " $resolver $symtest $symguard $mkdirs $fn 1"
        or die $@;
}

my $d    = Cwd::realpath( tempdir( CLEANUP => 1 ) );
my %subs = ( DOCROOT => $d );

sub mode_of { return ( ( stat $_[0] )[2] // 0 ) & 07777 }

my @MODEL = (
    { path => '{DOCROOT}/repairable', mode => '2775', on_upgrade => 'repair',
        applied_by => [ 'install', 'check' ] },
    { path => '{DOCROOT}/leftalone', mode => '2775', on_upgrade => 'leave',
        applied_by => [ 'install', 'check' ] },
    { path => '{DOCROOT}/checkonly', mode => '2775', on_upgrade => 'repair',
        applied_by => ['check'] },
);

# --- fresh: everything the installer owns gets its declared mode -------------
{
    create_runtime_paths( \@MODEL, \%subs, 'fresh' );
    is( sprintf( '%04o', mode_of("$d/repairable") ), '2775', 'fresh: repairable created' );
    is( sprintf( '%04o', mode_of("$d/leftalone") ),  '2775', 'fresh: leftalone created' );
    ok( !-e "$d/checkonly",
        'a check-only path is NEVER created by the installer - lazysite/git is '
            . 'made by the content-history plugin, not here' );
}

# --- upgrade: repair fixes a wrong mode, leave does not ---------------------
{
    chmod 0755, "$d/repairable";    # the reported failure: group write lost
    chmod 0755, "$d/leftalone";

    create_runtime_paths( \@MODEL, \%subs, 'upgrade' );

    is( sprintf( '%04o', mode_of("$d/repairable") ), '2775',
        'upgrade: a repair path is put back - the installer can now fix what '
            . 'previously only check --fix could' );
    is( sprintf( '%04o', mode_of("$d/leftalone") ), '0755',
        'upgrade: a leave path is untouched, so a deliberate tightening survives' );
}

# --- an entry with no policy keeps the OLD upgrade behaviour ----------------
# Absent means leave, so a row predating the field cannot change behaviour by
# being read with the new code.
{
    my @legacy = ( { path => '{DOCROOT}/legacy', mode => '2775',
            applied_by => [ 'install', 'check' ] } );
    create_runtime_paths( \@legacy, \%subs, 'fresh' );
    chmod 0755, "$d/legacy";
    create_runtime_paths( \@legacy, \%subs, 'upgrade' );
    is( sprintf( '%04o', mode_of("$d/legacy") ), '0755',
        'no on_upgrade means leave - a pre-field entry behaves as before' );
}

# --- the defensive default is the CONSERVATIVE one --------------------------
# It read ||= 'fresh', and 'fresh' is the branch that re-chmods. A default that
# only bites when a caller forgets should not be the destructive one.
{
    like( $src, qr/\$install_mode \|\|= 'upgrade'/,
        "the omitted-argument default is 'upgrade', not 'fresh'" );
}

done_testing();
