#!/usr/bin/perl
# Every shipped CGI surface must reach the deb payload, and every shipped vhost
# example must reach its flavour package.
#
# WHY. `debian/lazysite-common.install` names the payload files one by one. Add a
# new surface and it lands in the tarball automatically (the manifest globs) but
# NOT in the deb, because nobody edited that list. The tarball then works, the
# tests pass, and the feature is simply absent for every operator who installed
# from packages - which is most of them.
#
# That is exactly what happened to SM293's `lazysite-front.pl`: it was in the
# tarball, its tests passed, it served correctly from a real install of the
# tarball - and it was missing from the deb. Caught by inspecting the built
# artefact during the 0.10.8 cut, not by anything automatic.
#
# It is the same shape as t/lint/31's hand-maintained template list and
# t/lint/39's script list: a list somebody must remember to edit is a list that
# will be wrong, and the failure is silent in the direction that matters.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

subtest 'every root CGI surface is in the deb payload' => sub {
    my $install = slurp("$root/debian/lazysite-common.install");

    my @surfaces = sort map { s{\A\Q$root/\E}{}r } glob("$root/lazysite-*.pl");
    cmp_ok( scalar @surfaces, '>=', 6, 'found the CGI surfaces' );

    my @missing = grep { $install !~ /^\Q$_\E\s/m } @surfaces;
    is_deeply( \@missing, [],
        'every lazysite-*.pl is named in debian/lazysite-common.install' )
        or diag( join "\n  ",
        '',
        @missing,
        '',
        'These ship in the tarball and are ABSENT from the package. A site',
        'installed from the deb never receives them, and nothing else notices.' );
};

subtest 'every shipped vhost example is in its flavour package' => sub {
    for my $flavour (qw(apache nginx)) {
        my $install = slurp("$root/debian/lazysite-$flavour.install");
        my @examples =
            sort map { s{\A\Q$root/\E}{}r }
            glob("$root/installers/$flavour/*.conf.example");
        cmp_ok( scalar @examples, '>=', 2, "$flavour: found the examples" );

        my @missing = grep { $install !~ /^\Q$_\E\s/m } @examples;
        is_deeply( \@missing, [],
            "$flavour: every shipped example is packaged" )
            or diag( join "\n  ", '', @missing );
    }
};

subtest 'the operator-facing compliance documents are packaged' => sub {
    # An operations template that does not reach the operator is a template the
    # project wrote for itself. These carry obligations that attach to whoever
    # RUNS a lazysite instance - the reporting path, the named security contact,
    # the rehearsal cadence - none of which the project can discharge for them.
    #
    # Derived from the directory, not listed, for the reason this file exists.
    my $install = slurp("$root/debian/lazysite-common.install");

    my @operator_facing = sort map { s{\A\Q$root/\E}{}r }
        grep { !m{/TECHNICAL-FILE\.md\z} }    # project-side evidence index
        glob("$root/docs/compliance/*.md");
    cmp_ok( scalar @operator_facing, '>=', 3, 'found the compliance documents' );

    my @missing = grep { $install !~ /^\Q$_\E\s/m } @operator_facing;
    is_deeply( \@missing, [],
        'every operator-facing compliance document is in the deb payload' )
        or diag( join "\n  ",
        '',
        @missing,
        '',
        'An operator installing from the package would never see these, and',
        'the obligations in them are theirs rather than the project\'s.' );
};

done_testing();
