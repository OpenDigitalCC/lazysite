#!/usr/bin/perl
# SM402: the form handler recorded an identity it could not verify.
#
# form-handler.pl is NOT behind the auth wrapper. The shipped templates front
# only lazysite-processor.pl and lazysite-manager-api.pl with it, and /cgi-bin/
# is otherwise a plain ScriptAlias - so the processor's trust-header stripping
# never runs for this script, and HTTP_X_REMOTE_USER arrives exactly as the
# client sent it. There is no configuration under which it could be trusted:
# auth_proxy_trusted is consulted by the PROCESSOR, on the request the processor
# handles.
#
# IT WAS RECORDED TWICE, AND ONLY ONE OF THEM MATTERED.
#
#   `_auth_user` on the submission was DEAD. Every delivery target - file, SMTP,
#   webhook, and the separate form-smtp plugin - skips _-prefixed keys, so it
#   never reached a stored record, an email or a webhook. Worth stating plainly
#   because the original filing claimed an operator could see it in a
#   submissions list, and that was wrong.
#
#   The AUDIT ENTRY was live. An unverifiable name went into the actor column of
#   lazysite/logs/audit.log - the shared trail that manager-api, dav, mcp, oauth
#   and the users tool all write to with an identity they HAVE verified. A
#   forged name there is a false record in the one artefact whose entire purpose
#   is to say who did something.
#
# So the fix is not "drop the dead field". Dropping only the dead one would have
# looked like the fix while leaving the live one in place.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $handler = "$root/plugins/form-handler.pl";
plan skip_all => "no $handler" unless -f $handler;

my $src = do { open my $fh, '<', $handler or die $!; local $/; <$fh> };

# Strip comments before asserting on CODE, or a comment explaining why the
# header is not read would satisfy a search for the header being read.
( my $code = $src ) =~ s/^\s*#.*$//mg;

unlike( $code, qr/\$ENV\{HTTP_X_REMOTE_USER\}/,
    'the handler does not read the trust header at all' );
unlike( $code, qr/_auth_user/,
    'and no longer tags submissions with an unverified name' );

like( $code, qr/_audit_submission\(\s*\$name,\s*''/,
    'the audit entry records NO actor, because none was verified' );
unlike( $code, qr/_audit_submission\([^)]*\$auth_user/,
    'and specifically not the header-derived one' );

# The address is a fact that IS known, and must still be recorded - dropping the
# actor should not quietly drop the provenance with it.
like( $code, qr/_audit_submission\([^)]*REMOTE_ADDR/,
    'the submitting address is still audited' );

# The delivery targets skip _-prefixed keys. Asserted because it is the reason
# `_auth_user` was harmless, and if it ever stopped being true a future
# _-prefixed field would start leaking into stored records.
my @loops = ( $code =~ /for my \$k \( sort keys %\$form \) \{\s*next if \$k =~ [^;]+;/g );
cmp_ok( scalar @loops, '>=', 3,
    'the file, SMTP and webhook targets each skip _-prefixed keys' );

my $smtp = "$root/plugins/form-smtp.pl";
SKIP: {
    skip 'no form-smtp plugin', 1 unless -f $smtp;
    my $s = do { open my $fh, '<', $smtp or die $!; local $/; <$fh> };
    like( $s, qr/for my \$k \( sort keys %\$form \) \{\s*next if \$k =~/,
        'and so does the separate SMTP plugin' );
}

done_testing();
