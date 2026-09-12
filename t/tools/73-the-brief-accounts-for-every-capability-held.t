#!/usr/bin/perl
# SM859: a partner's brief accounts for every capability its grant holds.
#
# The brief lists `capabilities:` derived from the same key list whoami answers
# from - deliberately, since SM662, so the two cannot disagree - and then DELETES
# ui, api and mcp on the grounds that they are channels rather than authority
# (SM086). But `webdav` stays in the list, and webdav gates a surface exactly as
# api and mcp do. So a grant holding webdav, api, mcp and manage_content is
# briefed as holding TWO capabilities, and a reader comparing the brief with
# whoami counts a difference with nothing to explain it.
#
# The site agent hit precisely that on edge: "the brief's capability snapshot
# listed six, and whoami reports eight - it does not mention api or mcp, the two
# channel capabilities, though the brief's own YAML does list webdav." Its
# reading was that two capabilities had been added since the brief was written.
# They had not. The brief was silent about an omission it makes on purpose.
#
# The fix is not to relitigate SM086: it is for the brief to SAY what it leaves
# out and where that is stated instead.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir grant_caps add_account);

my $root = repo_root();

sub brief_for {
    my (@caps) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: T\n";
    close $c;
    add_account( $d, 'partner' );
    grant_caps( $d, 'partner', @caps );
    return scalar
        qx($^X \Q$root/tools/lazysite-users.pl\E --docroot \Q$d\E brief partner 2>&1);
}

subtest 'a channel the grant holds is stated, not silently dropped' => sub {
    my $brief = brief_for(qw(webdav api mcp manage_content));

    my ($caps) = $brief =~ /^(capabilities:.*?)^\w/ms;
    like( $caps, qr/manage_content/, 'the authority capabilities are listed' );
    like( $caps, qr/webdav/,         'including webdav' );

    like( $brief, qr/^channels:/m, 'and the channels are stated in their own block' )
        or diag( 'A grant holding api and mcp was briefed as holding neither, '
            . 'while webdav - which gates a surface in the same way - was '
            . 'listed. The reader cannot tell an omission from an absence.' );
    like( $brief, qr/^channels:.*?\bapi:\s*true/ms, 'api is named as held' );
    like( $brief, qr/^channels:.*?\bmcp:\s*true/ms, 'mcp is named as held' );
};

subtest 'a channel the grant does NOT hold says so' => sub {
    my $brief = brief_for(qw(webdav manage_content));
    like( $brief, qr/^channels:.*?\bapi:\s*false/ms, 'api: false' );
    like( $brief, qr/^channels:.*?\bmcp:\s*false/ms, 'mcp: false' );
    unlike( $brief, qr/^\s+- api$/m, 'and it is not smuggled into the capability list' );
};

subtest 'the block says which answer is authoritative' => sub {
    my $brief = brief_for(qw(webdav api mcp manage_content));
    like( $brief, qr/whoami/, 'whoami is named as the authority' )
        or diag( 'The brief is a snapshot taken when it was minted; whoami is '
            . 'live. A reader comparing them needs to be told which wins.' );
};

done_testing();
