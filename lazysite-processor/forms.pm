package main;

# lazysite-processor/forms.pm - the processor's forms and fenced divs.
#
# HOLDS   convert_fenced_form() and _render_form(): a `:::form` block becomes
#         the form's markup - fields, options, prefill from the request's raw
#         query (escaped here), the outcome banner from a closed sentence map,
#         the step stylesheet link - with the timing-token placeholders that
#         output_page fills per response. _render_form is the line loop and
#         the assembly; its parts are subs of their own (SM1012):
#         _form_rule_tokens and _form_rules_from_tokens (a field's rules),
#         _form_field_value (its value, before escaping), _form_server_rule
#         (what the server holds it to), a _form_field_* renderer per field
#         kind in @FORM_FIELD_KINDS, and _form_outcome_banner.
#         _write_form_rules (SM934 FV1), the rules the handler will hold a
#         submission to, written beside the form's conf at render;
#         load_form_secret, the form HMAC secret (output_page and the form
#         handler read it); _form_options, _form_attr, _esc_attr,
#         _form_step_css, _form_step_script; convert_fenced_divs, the
#         `::: class` box pass that renders its body's Markdown.
# OWNS    the form's markup and the rules file derived from it; which class
#         names a fenced div may carry.
# CALLS   convert_md, _tt_inert, _esc_html, _lazysite_version, _draft_requested,
#         log_event (the script and its parts); make_path, encode_json (imported by the
#         script's `use`, before its parts load).
# READS   $LAZYSITE_DIR, %RENDER_QUERY, $FORM_TS_PLACEHOLDER,
#         $FORM_TK_PLACEHOLDER (the script's, declared `our` there; the two
#         placeholders are set in the script's BEGIN, which runs after this
#         part loads and before any sub here is called).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S11). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

our ( $FORM_TS_PLACEHOLDER, $FORM_TK_PLACEHOLDER, $LAZYSITE_DIR, %RENDER_QUERY );

# --- Forms ---

sub load_form_secret {
    my $secret_path = "$LAZYSITE_DIR/forms/.secret";
    my $forms_dir   = "$LAZYSITE_DIR/forms";
    make_path($forms_dir) unless -d $forms_dir || _draft_requested();    # SM1030

    if ( -f $secret_path ) {
        open( my $fh, '<', $secret_path ) or do {
            log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'cannot read form secret', error => $! );
            return '';
        };
        chomp( my $s = <$fh> );
        close($fh);
        return $s if $s;
    }

    # M-6: fail closed if CSPRNG unavailable.
    open( my $rand, '<:raw', '/dev/urandom' )
        or die "Cannot open /dev/urandom - no CSPRNG available: $!\n";
    my $raw = '';
    my $got = read( $rand, $raw, 32 );
    close($rand);
    die "Short read from /dev/urandom ($got of 32 bytes)\n"
        unless defined $got && $got == 32;
    my $s = unpack( 'H*', $raw );

    # SM1030: a draft's form tokens are never posted, so a site with no secret
    # yet gets a throwaway one rather than a file.
    return $s if _draft_requested();

    open( my $fh, '>', $secret_path ) or do {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'cannot write form secret', error => $! );
        return $s;
    };
    # 0660: identity-shared secret (site-user CLI/dev-server + www-data CGI,
    # via the setgid forms dir group). Owner-only minting locks the CGI out.
    chmod 0o660, $secret_path;
    print $fh "$s\n";
    close($fh);
    return $s;
}

# SM401: split a rule's option list, respecting quotes.
#
# It was `split /,/`, with quotes stripped afterwards - so a quoted option
# containing a COMMA became two options. `select:"Smith, John","Jones"` rendered
# three choices, two of them wrong, and nothing said so: the form worked, it just
# offered the wrong answers. Spaces and parentheses inside a quoted option were
# always fine and still are; the comma is the case that was broken.
sub _form_options {
    my ($raw) = @_;
    my @out;
    my $cur = '';
    my $q   = 0;
    for my $ch ( split //, $raw ) {
        if ( $ch eq '"' ) { $q = !$q; next }
        elsif ( $ch eq ',' && !$q ) { push @out, $cur; $cur = ''; next }
        $cur .= $ch;
    }
    push @out, $cur;
    my @clean;
    for my $o (@out) {
        $o =~ s/\A\s+|\s+\z//g;
        push @clean, $o if length $o;
    }
    return \@clean;
}

# Escape an option for use as BOTH an attribute value and visible text. The two
# were previously interpolated raw, so an option containing a quote or an
# ampersand produced broken markup on a page an author controls.
sub _form_attr {
    my ($v) = @_;
    $v = '' unless defined $v;
    $v =~ s/&/&amp;/g;
    $v =~ s/</&lt;/g;
    $v =~ s/>/&gt;/g;
    $v =~ s/"/&quot;/g;
    return $v;
}

# The two-entity attribute escape: & and ", nothing else (PR-11). Three sites in
# _render_form wrote this pair out inline - placeholder, accept, pattern - and
# every one of them lands in an attribute value, never in element text.
#
# This is deliberately NOT _form_attr above: that one also escapes < and >, so
# reaching for it here would change the bytes of any value carrying an angle
# bracket. Same reason _esc_html stays separate - it escapes the apostrophe too.
sub _esc_attr {
    my ($v) = @_;
    $v = '' unless defined $v;
    $v =~ s/&/&amp;/g;
    $v =~ s/"/&quot;/g;
    return $v;
}

sub convert_fenced_form {
    my ( $text, $meta ) = @_;
    $meta //= {};

    # SM161: accept BOTH ":::form" and "::: form" as the opening fence. The
    # space used to be required ([ \t]+), but the bind_form tool's own example
    # (and pandoc's own fenced-div convention) writes ":::form" with no space, so
    # an agent following the docs shipped a form that rendered as literal text.
    $text =~ s{
        ^:::[ \t]*form[ \t]*\n    # opening :::form  OR  ::: form
        (.*?)                      # field definitions
        ^:::[ \t]*\n               # closing :::
    }{
        _render_form( $1, $meta );
    }gesmx;

    return $text;
}

# SM934 FV1: THE RULES THE SERVER WILL ENFORCE, WRITTEN WHERE THE FORM WAS
# RENDERED.
#
# The ruling (2026-10-02) chose a RENDER-TIME SIDECAR over the two alternatives,
# and the reason is the hazard rather than convenience. A form's field rules live
# in the page's `:::form` block; the handler has never seen them - the form's
# .conf carries targets and upload limits, not fields - so a direct POST was
# checked against nothing. Giving the handler the rules needs them to arrive by a
# path the submitter cannot choose, and there were three:
#
#   - store them in the .conf: a hand-edited `:::form` block then DRIFTS from the
#     conf, and the server enforces a rule the browser never showed - which is
#     SM921's hazard in its original direction;
#   - have the handler parse the page: `_page` is visitor-supplied (it is
#     validated as a same-site path and tied to nothing), so a submitter could
#     name a page with no rules and bypass the lot. Reading the page named in the
#     .conf avoids that and costs a second implementation of the form grammar;
#   - THIS: the rules are derived at render, so what the server enforces is
#     exactly what the visitor was served. Drift is impossible by construction.
#
# IT LIVES BESIDE THE FORM'S CONF, NOT IN THE CACHE. The cache is clearable, and
# a cleared cache would leave a form enforcing nothing until its page was fetched
# again. `lazysite/forms/` is already denied to every grant and is where the
# handler looks, so the file survives a cache clear and an upgrade.
#
# A FORM NEVER RENDERED SINCE THE UPGRADE HAS NO FILE, AND THEN NOTHING IS
# ENFORCED. That is the safe direction and it is the same answer FV2 gives for an
# uncompilable pattern: absent means absent. The alternative - refuse everything
# until a page is rendered - would take working forms off live sites on upgrade.
#
# DERIVED, NEVER AUTHORED. It is rewritten on every render of the block, so an
# edit here is lost; the header in the file says so, because a file in
# `lazysite/forms/` otherwise looks exactly like one an operator maintains.
#
# Failure is silent BY DESIGN: a form that cannot write its sidecar must still
# render. A page that would not display because its validation metadata could not
# be saved is a worse failure than the one this closes.
sub _write_form_rules {
    my ( $form_name, $rules ) = @_;
    return if _draft_requested();    # SM1030: a draft render writes nothing
    return unless defined $form_name && $form_name =~ /\A[A-Za-z0-9_-]+\z/;
    my $dir = "$LAZYSITE_DIR/forms";
    return unless -d $dir && -w $dir;
    my $path = "$dir/$form_name.rules";
    my $tmp  = "$path.$$";
    my $json = eval {
        encode_json( {
                note => 'DERIVED at render by lazysite-processor.pl (SM934)'
                    . ' - rewritten on every render, do not edit',
                form    => $form_name,
                version => 1,
                fields  => $rules,
        } );
    };
    return unless defined $json;
    open my $fh, '>', $tmp or return;
    binmode $fh;
    my $ok = print {$fh} $json;
    $ok &&= close $fh;
    if ( !$ok ) { unlink $tmp; return }
    chmod 0640, $tmp;
    rename $tmp, $path or unlink $tmp;
    return;
}

# SM1012 S1: A FIELD'S RULES, AS TOKENS - cut from _render_form's line loop.
#
# Tokens are whitespace-separated, but a key:"value" may quote a value that
# contains spaces (e.g. placeholder:"Your full name" or
# pattern:"[0-9 +()-]{7,20}"). $name is for the unclosed-quote warning only.
# Both `last`s are this sub's own `while`'s.
sub _form_rule_tokens {
    my ( $rules_str, $name ) = @_;
    my @rule_tokens;
    my $rs = $rules_str;
    while ( length $rs ) {
        $rs =~ s/^\s+//;
        last unless length $rs;
        # select: takes the REST of the line - its comma-separated options may
        # contain spaces, so put select: last among a field's rules. (Quotes
        # around the list or an option are tolerated and stripped on render.)
        # SM401: radio/checklist/checklist-qty take the REST of the line for
        # the same reason select: does - their comma-separated options may
        # contain spaces, so they go last among a field's rules.
        if ( $rs =~ s/^((?:select|radio|checklist|checklist-qty):.*)\z//s ) {
            push @rule_tokens, $1;
        }

        # SM921: `pattern:` TAKES THE REST OF THE LINE TOO, for the same reason
        # the option lists do - its value may contain a space, and a regex is
        # where a space is most likely to be meant literally.
        #
        # It did not, and the result was silent: `pattern:[0-9 ()+.-]{6,30}`
        # rendered `pattern="[0-9"`, which IS a valid regex, so nothing was
        # ignored and nothing was reported - the field simply refused almost
        # every value. Under-rejecting is at least visible to whoever tests the
        # form; over-rejecting a valid phone number looks like the visitor's
        # fault.
        #
        # MEASURED BEFORE CHANGING IT, because taking the rest of the line
        # swallows anything written after it - a `required` after a pattern
        # would become part of the pattern and the field would quietly stop
        # being required. Of the 16 form-field lines carrying a `pattern:` rule
        # in the shipped tree and the live sites repo, exactly ZERO have another
        # rule after it (tmp/pattern-population.pl); every author who has met
        # this already puts the pattern last, which is also what the option
        # lists document. The quoted form `pattern:"..."` is untouched and is
        # handled below, so a pattern that must be followed by another rule has
        # a spelling that still works.
        elsif ( $rs =~ s/^(pattern:(?!")\S.*)\z//s ) {
            ( my $tok = $1 ) =~ s/\s+\z//;
            push @rule_tokens, $tok;
        }
        # SM871: THE QUOTED FORM UNDERSTANDS AN ESCAPED QUOTE.
        #
        # This was `"([^"]*)"`, which cannot contain a quote at all - so
        # `value:"before \" x"` stopped at the inner quote, the value became
        # `before \`, and THE REMAINDER WENT BACK THROUGH THIS LOOP as more
        # rules. That second part is the one that bites: a leftover chunk
        # like `max:5"` still matches the valued rules below, because they
        # are matched with an unanchored regex rather than by equality. So a
        # stray quote in a default could change a field's max, min, pattern
        # or placeholder. (It could NOT switch on `required` - measured, and
        # contrary to this filing's own headline example: the flags are
        # compared with `eq`, so `required"` matches nothing and is dropped.)
        #
        # `(?:[^"\\]|\\.)*` steps over an escaped character, so the value
        # runs to the real closing quote, and only `\"` is unescaped after -
        # NOT every backslash. That distinction is load-bearing: `pattern:`
        # values carry regex escapes, and unescaping all of them would turn
        # `\d` into `d` and silently break every pattern in the field.
        #
        # THE TRADE, stated: a value whose last character is a backslash now
        # reads as an escaped quote and so as unclosed. That is the correct
        # reading once `\"` means a quote, and it is warned about below
        # rather than being silent.
        elsif ( $rs =~ s/^([A-Za-z]+:)"((?:[^"\\]|\\.)*)"// ) {
            my ( $key, $val ) = ( $1, $2 );
            $val =~ s/\\"/"/g;
            push @rule_tokens, "$key$val";
        }

        # SM871: A QUOTED RULE THAT NEVER CLOSES IS SAID OUT LOUD.
        #
        # The behaviour is deliberately unchanged - the chunk is tokenised on
        # whitespace exactly as before, so the field's OTHER rules still
        # apply. Dropping them would be worse than the fault: a `required`
        # written after a malformed value would silently become optional,
        # which is a form weakening itself over a typo. So this adds the
        # diagnosis and nothing else. SM856 set the precedent for saying
        # what could not be read in this same function.
        elsif ( $rs =~ /^([A-Za-z]+:)"/ ) {
            log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
                'form rule has an unclosed quoted value',
                field => $name, rule => $1,
                hint  => 'close the quote; write \\" for a quote inside it' );
            $rs =~ s/^(\S+)// and push @rule_tokens, $1;
        }
        elsif ( $rs =~ s/^(\S+)// ) { push @rule_tokens, $1; }
        else                        { last; }
    }
    return @rule_tokens;
}

# SM1012 S2: A FIELD'S RULES, FROM ITS TOKENS - cut from _render_form's line
# loop. Each token sets one rule; a token that is none of them is ignored.
sub _form_rules_from_tokens {
    my (@rule_tokens) = @_;
    my %rules;
    for my $r (@rule_tokens) {
        if    ( $r eq 'required' ) { $rules{required} = 1; }
        elsif ( $r eq 'optional' ) { $rules{optional} = 1; }
        elsif ( $r eq 'email' )    { $rules{type}     = 'email'; }
        elsif ( $r =~ /^(tel|date|time|number|url|password)$/ ) { $rules{type}     = $1; }
        elsif ( $r eq 'textarea' )                              { $rules{textarea} = 1; }
        elsif ( $r eq 'file' )                                  { $rules{file}     = 1; }
        elsif ( $r eq 'multiple' )                              { $rules{multiple} = 1; }
        elsif ( $r =~ /^accept:(.+)/ )                          { $rules{accept}   = $1; }

        # SM905 U3: `capture` on a file input, which is how a phone offers
        # the camera directly instead of the file picker. The grammar rendered
        # accept, multiple and required and had no way to ask for this, so an
        # author wanting a photograph had to hand-write the input - which the
        # forms contract does not allow for content.
        #
        # `capture` alone lets the browser choose; `capture:user` asks for the
        # front camera and `capture:environment` for the rear one. Those are
        # the only two the HTML specification defines, so anything else is
        # dropped rather than passed through to an attribute nobody honours.
        elsif ( $r eq 'capture' )                       { $rules{capture} = '' }
        elsif ( $r =~ /^capture:(user|environment)\z/ ) { $rules{capture} = $1 }
        elsif ( $r =~ /^select:(.+)/ ) { $rules{select} = _form_options($1); }
        elsif ( $r =~ /^radio:(.+)/ )  { $rules{radio}  = _form_options($1); }
        elsif ( $r =~ /^checklist-qty:(.+)/ ) {
            $rules{checklist} = _form_options($1);
            $rules{qty}       = 1;
        }
        elsif ( $r =~ /^checklist:(.+)/ )   { $rules{checklist}   = _form_options($1); }
        elsif ( $r =~ /^max:(\d+)/ )        { $rules{max}         = $1; }
        elsif ( $r =~ /^min:(\d+)/ )        { $rules{min}         = $1; }
        elsif ( $r =~ /^pattern:(.+)/ )     { $rules{pattern}     = $1; }
        elsif ( $r =~ /^placeholder:(.+)/ ) { $rules{placeholder} = $1; }
        elsif ( $r =~ /^value:(.*)/s )      { $rules{value}       = $1; }
        elsif ( $r =~ /^prefill:(\S+)/ )    { $rules{prefill}     = $1; }
    }
    return %rules;
}

# SM1012 S3: A FIELD'S VALUE, BEFORE IT IS ESCAPED - cut from _render_form's
# line loop. The `value:` literal, or the request's value of the `prefill:`
# parameter when the page declares it in query_params: and this request carries
# it (SM856); an undeclared parameter is logged and leaves the literal. Raw:
# the caller escapes it for where it goes (SM869).
sub _form_field_value {
    my ( $name, $meta, %rules ) = @_;
    my $value = $rules{value};
    if ( defined $rules{prefill} ) {
        my $p = $rules{prefill};
        my @declared = @{ ( ref $meta->{query_params} eq 'ARRAY' ) ? $meta->{query_params} : [] };
        if ( grep { $_ eq $p } @declared ) {
            if ( defined $RENDER_QUERY{$p} && length $RENDER_QUERY{$p} ) {
                $value = $RENDER_QUERY{$p};
            }
        }
        else {
            log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
                'form prefill names an undeclared query parameter',
                field => $name, param => $p,
                hint  => "add it to the page's query_params: list" );
        }
    }
    return $value;
}

# SM1012 S4: THE RULE THE SERVER HOLDS THIS FIELD TO - cut from _render_form's
# line loop. One rule, or none for a chooser that is not marked required.
#
# SM934 FV1: the rules this field will be held to at submission.
#
# DECLARED VALUES ONLY - no judgement is made here. Whether a `pattern`
# is one a browser would actually compile is decided by
# Lazysite::Validate::html_pattern_problem, which lint 204 holds must
# exist exactly once and be called by name; the render path cannot load
# a module (ADR 0001), so the handler makes that call instead. Copying
# the character list here is precisely what that lint forbids.
#
# `max` carries its MEANING, not just its number: on a number field the
# browser gets `max=` (a value bound) and everywhere else `maxlength=`
# (a length bound). Recording 1000 against a text field with no declared
# max is deliberate - that IS what the browser was told, and a server
# that enforced nothing there would be looser than the page.
# IT MIRRORS THE RENDER BRANCH BY BRANCH, because an entry that does not
# is a server stricter or looser than the page. A chooser gets `required`
# and nothing else - there is no maxlength or pattern on a `<select>` to
# be parity with - and a multi-box checklist gets nothing, because the
# render deliberately withholds `required` from a group of more than one
# (SM888 A5: marking them all required would demand every option).
sub _form_server_rule {
    my ( $name, $max, $eff_pat, %rules ) = @_;
    my @server_rules;
    my $chooser = $rules{select} || $rules{radio} || $rules{checklist};
    if ($chooser) {
        my $marked =
            $rules{checklist}
            ? ( $rules{required} && @{ $rules{checklist} } == 1 )
            : $rules{required};
        push @server_rules, { name => $name, required => 1 } if $marked;
    }
    else {
        push @server_rules, {
            name => $name,
            ( $rules{required} ? ( required => 1 )            : () ),
            ( $rules{file}     ? ( file     => 1 )            : () ),
            ( $rules{type}     ? ( type     => $rules{type} ) : () ),
            ( defined $eff_pat ? ( pattern  => $eff_pat )     : () ),
            ( ( $rules{type} // '' ) eq 'number'
                ? ( ( defined $rules{max} ? ( max => $rules{max} ) : () ),
                    ( defined $rules{min} ? ( min => $rules{min} ) : () ),
                    bound => 'value',
                    )
                : ( max => $max, bound => 'length' )
            ),
        };
    }
    return @server_rules;
}

# SM1012 S5: A FILE FIELD - cut from _render_form, like each field kind's
# renderer. Every one takes the same arguments, ( $name, $value, $max,
# $req_attr, $ph_attr, $val_attr, $eff_pat, %rules ), whether it reads
# them all or not, so that the kinds are rows of one table.
sub _form_field_file {
    my ( $name, $value, $max, $req_attr, $ph_attr, $val_attr, $eff_pat, %rules ) = @_;
    my $field_html;
    my $acc = '';
    if ( defined $rules{accept} ) {
        my $a = _esc_attr( $rules{accept} );
        $acc = qq( accept="$a");
    }
    my $mult = $rules{multiple} ? ' multiple' : '';
    # SM905 U3: bare `capture` is a valid boolean attribute; with a value
    # it names which camera.
    my $cap = '';
    if ( defined $rules{capture} ) {
        $cap = length $rules{capture}
            ? ' capture="' . _esc_attr( $rules{capture} ) . '"'
            : ' capture';
    }
    $field_html = qq(    <input type="file" name="$name" id="$name")
        . $acc . $mult . $cap . qq($req_attr>\n);
    return $field_html;
}

# SM1012 S5: A TEXTAREA FIELD (arguments as _form_field_file's).
sub _form_field_textarea {
    my ( $name, $value, $max, $req_attr, $ph_attr, $val_attr, $eff_pat, %rules ) = @_;
    my $field_html;
    # A textarea carries its value as CONTENT, not an attribute - and it
    # is escaped as text, not as an attribute, or a `<` in a prefilled
    # value would open a tag inside the field (SM856).
    # SM869: the same rule as the value attribute in _render_form - escaped here,
    # whatever the source, and TT-inert.
    my $ta
        = ( defined $value && length $value )
        ? _tt_inert( _esc_html($value) )
        : '';
    $field_html = qq(    <textarea name="$name" id="$name")
        . qq( maxlength="$max"$ph_attr$req_attr>$ta</textarea>\n);
    return $field_html;
}

# SM1012 S5: A SELECT FIELD (arguments as _form_field_file's).
sub _form_field_select {
    my ( $name, $value, $max, $req_attr, $ph_attr, $val_attr, $eff_pat, %rules ) = @_;
    my $field_html;
    $field_html = qq(    <select name="$name" id="$name"$req_attr>\n);
    $field_html .= qq(      <option value="">-- Select --</option>\n);
    for my $opt ( @{ $rules{select} } ) {
        my $e = _form_attr($opt);
        $field_html .= qq(      <option value="$e">$e</option>\n);
    }
    $field_html .= qq(    </select>\n);
    return $field_html;
}

# SM1012 S5: A RADIO GROUP (arguments as _form_field_file's).
sub _form_field_radio {
    my ( $name, $value, $max, $req_attr, $ph_attr, $val_attr, $eff_pat, %rules ) = @_;
    my $field_html;
    $field_html = qq(    <div class="form-options" role="radiogroup">\n);
    my $i = 0;
    for my $opt ( @{ $rules{radio} } ) {
        my $e  = _form_attr($opt);
        my $id = "$name-" . $i++;
        $field_html
            .= qq(      <label class="form-option" for="$id">)
            . qq(<input type="radio" name="$name" id="$id" value="$e"$req_attr> $e</label>\n);
    }
    $field_html .= qq(    </div>\n);
    return $field_html;
}

# SM1012 S5: A CHECKBOX GROUP, WITH A QUANTITY PER BOX FOR checklist-qty
# (arguments as _form_field_file's).
sub _form_field_checklist {
    my ( $name, $value, $max, $req_attr, $ph_attr, $val_attr, $eff_pat, %rules ) = @_;
    my $field_html;
    # NO `required` ON A CHECKBOX GROUP OF MORE THAN ONE. On radio
    # inputs the browser treats required as "one of the group"; on
    # checkboxes it means THIS box, so marking them all required would
    # demand every option be ticked - the opposite of what a
    # multi-select means.
    #
    # SM888 A5: A GROUP OF ONE IS THE EXCEPTION, and the reasoning above
    # is what makes it one. With a single box there is no difference
    # between "this box" and "one of the group" - they are the same box -
    # so the browser's meaning of `required` is exactly the author's.
    # Omitting it there was the general rule applied past its reason: a
    # field marked required submitted empty, and the form accepted it.
    # The field is most often a single consent tick, which is the case
    # where an unticked box mattering most is also the case it was least
    # enforced.
    my $one_box = @{ $rules{checklist} } == 1;
    my $box_req = $one_box ? $req_attr : '';
    $field_html = qq(    <div class="form-options">\n);
    my $i = 0;
    for my $opt ( @{ $rules{checklist} } ) {
        my $e  = _form_attr($opt);
        my $id = "$name-" . $i++;
        $field_html
            .= qq(      <label class="form-option" for="$id">)
            . qq(<input type="checkbox" name="$name" id="$id" value="$e"$box_req> $e);

        # The quantity travels in the NAME, so the handler can fold it
        # back without being told the form's field types.
        $field_html .= qq( <input type="number" class="form-option-qty")
            . qq( name="$name~qty~$e" min="0" step="1" aria-label="$e quantity">)
            if $rules{qty};
        $field_html .= qq(</label>\n);
    }
    $field_html .= qq(    </div>\n);
    return $field_html;
}

# SM1012 S5: AN <input> - text, or the declared type - for a field that is
# none of the other kinds (arguments as _form_field_file's).
sub _form_field_input {
    my ( $name, $value, $max, $req_attr, $ph_attr, $val_attr, $eff_pat, %rules ) = @_;
    my $field_html;
    my $type  = $rules{type} || 'text';
    my $attrs = '';
    if ( $type eq 'number' ) {
        # For numbers, min/max are value bounds (not maxlength).
        $attrs .= qq( min="$rules{min}") if defined $rules{min};
        $attrs .= qq( max="$rules{max}") if defined $rules{max};
    }
    else {
        $attrs .= qq( maxlength="$max");
    }
    # tel gets a default validation pattern unless overridden.
    #
    # SM921: ESCAPED, AND THE BOUND WIDENED, because the previous default
    # did not compile and therefore validated nothing. A browser compiles
    # `pattern` with the `v` flag, under which `(`, `)` and a hyphen at the
    # end of a character class are syntax errors - and the specification's
    # answer to an uncompilable pattern is to ignore the attribute in full.
    # So `[\d\s()+.-]{6,20}` was not a loose pattern, it was no pattern: an
    # owner typed the single letter S into their phone field and was
    # allowed. Re-measured here against node v20.19.2's own `v` flag rather
    # than trusted from the filing (tmp/measure-v-flag-patterns.js): the
    # shipped default is uncompilable, this one compiles and rejects "S".
    #
    # {6,30} because `+33 (0) 1 89 48 00 40` is 21 characters - a French
    # number written the way France writes it failed the old bound even
    # once the pattern compiled, which would have turned a silent fault
    # into a visible one for every caller in that country.
    # SM934: $eff_pat, computed by _render_form, so the attribute the browser gets
    # and the rule the handler enforces are the same expression.
    my $pat = $eff_pat;
    if ( defined $pat ) {
        $pat = _esc_attr($pat);
        $attrs .= qq( pattern="$pat");
    }
    $field_html = qq(    <input type="$type" name="$name" id="$name")
        . $attrs . $ph_attr . $val_attr . qq($req_attr>\n);
    return $field_html;
}

# SM1012 S6: THE OUTCOME BANNER - cut from _render_form. When this request's
# query string carries an outcome for THIS form (SM415), the banner above it:
# an engine sentence from the closed %SAID map for ok and ok-processing, and
# a refusal CODE from %REFUSED (SM1124 F-3), and anything else the generic
# sentence. The outcome is never printed. Empty when there is no outcome.
sub _form_outcome_banner {
    my ( $form_name, $fields ) = @_;
    my $banner = '';
    my $qs     = $ENV{QUERY_STRING} // '';
    if ( $qs =~ /(?:\A|&)form=\Q$form_name\E(?:&|\z)/ && $qs =~ /(?:\A|&)outcome=([^&]*)/ ) {
        my $o = $1;
        $o =~ tr/+/ /;
        $o =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
        # SM869: decoded as parse_query_string decodes (non-ASCII was mojibake),
        # and escaped as every sink into a pre-template body is: all five
        # characters, then TT-inert - a `[%` here used to run.
        $o = eval { decode( 'UTF-8', $o, 1 ) } // $o;
        $o = substr( $o, 0, 300 );
        # SM579: A SECOND SUCCESS STATE, AND THE VOCABULARY IS CLOSED.
        #
        # There was one success sentence and one style for everything else, so a
        # connector call that SUCCEEDED could only say "your message has been
        # sent" - which is untrue when nothing was sent to a person - or be shown
        # to the visitor in form-status-error with role="alert".
        #
        # THE WORDING IS KEYED, NEVER CARRIED. The query string is
        # attacker-writable by construction (SM415), so the sentence comes out
        # of this closed map and the outcome only SELECTS one. That is why author
        # copy was refused for this: text travelling in the URL would let a
        # crafted link put any sentence on the page in the SUCCESS style, which is
        # a materially better phishing aid than the red banner already is. An
        # attacker choosing between two engine sentences gains nothing.
        #
        # THE HANDLER HOLDS THE SAME SENTENCES, because it answers the JS path
        # with them in JSON and the render path is module-free (ADR 0001) - the
        # same shape as _acl_allows_read's twin, and pinned the same way, by a
        # lint rather than by hoping.
        my %SAID = (
            ok => 'Thank you - your message has been sent.',
            # A connector delivered: something left the site for a service rather
            # than reaching a person. True whether or not the connector keeps an
            # answer, and it deliberately promises neither a reply nor a page -
            # only the author knows whether the site shows the answer anywhere.
            'ok-processing' =>
                'Thank you - your submission has been received and sent for processing.',
        );
        # SM1124 F-3: A REFUSAL IS A CODE TOO. This banner printed any other
        # outcome, escaped, as "the refusal text" - so a link carrying
        # `outcome=<any words>` made the site's own page say them (the 0.15.9 walk:
        # `outcome=zz59+probe+text`; escaped, so not script, but a phone number or
        # "your account is suspended" in the site's voice). The handler now
        # redirects with a short code and, where the sentence holds a number or a
        # field's name, a separate plain parameter. The wording is this table's;
        # t/lint/156 holds it to the handler's %REFUSAL_SAID. A code the table
        # does not hold, or a parameter that is not of its shape, shows ONE
        # generic sentence - never the code, never any parameter's text.
        my %REFUSED = (
            'unavailable' => 'This form is not accepting submissions right now. Please contact the site owner.',
            'undelivered' => 'This form is not accepting submissions right now (nothing accepted the submission: its delivery is switched off or refused it - the site owner can see why in the event log). Please contact the site owner.',
            'no-uploads'     => 'This form does not accept file uploads.',
            'too-many-files' => 'Too many files (max {n}).',
            'file-too-large' => 'A file is too large (max {n} KiB).',
            'file-type'      => 'A file is of a type this form does not accept.',
            'empty'          => 'Please fill in the form before submitting.',
            'too-fast'       => 'That was too quick - please try again in a moment.',
            'expired' => 'This form was open too long and has expired - please reload the page and send it again.',
            'rate' => 'Too many submissions of this form from your address in the last hour. Please try again in about {retry} {unit}.',
            'field-long' => 'The \'{field}\' field is too long (limit {n} KB). Nothing was saved - shorten it and send the form again.',
            'field-required'   => 'The \'{field}\' field is required.',
            'field-email'      => 'The \'{field}\' field needs an email address.',
            'field-url'        => 'The \'{field}\' field needs a web address.',
            'field-number'     => 'The \'{field}\' field needs a number.',
            'field-max-length' => 'The \'{field}\' field is too long (limit {n}).',
            'field-max'        => 'The \'{field}\' field must be {n} or less.',
            'field-min'        => 'The \'{field}\' field must be {n} or more.',
            'field-pattern'    => 'The \'{field}\' field is not in the expected format.',
            'error'            => 'An error occurred - please try again.',
        );
        my %SHAPE = (
            retry => qr/\A\d{1,6}\z/,
            n     => qr/\A-?\d{1,15}(?:\.\d{1,6})?\z/,
            field => qr/\A[A-Za-z0-9_.-]{1,64}\z/,
        );
        my $generic = 'Your submission could not be accepted. Please try again.';
        if ( defined $SAID{$o} ) {
            $banner = qq(<p class="form-status form-status-ok" role="status">$SAID{$o}</p>\n);
        }
        else {
            my $text = $o =~ /\A[a-z-]{1,40}\z/ ? $REFUSED{$o} : undef;
            if ( defined $text ) {
                my %p;
                for my $k ( keys %SHAPE ) {
                    next unless $qs =~ /(?:\A|&)\Q$k\E=([^&]*)/;
                    my $v = $1;
                    $p{$k} = $v if $v =~ $SHAPE{$k};
                }
                $p{retry} = 60 if defined $p{retry} && $p{retry} > 60;
                $p{unit}  = $p{retry} == 1 ? 'minute' : 'minutes' if defined $p{retry};

                # A field is named only if THIS form declares it: the page, not the
                # link, says which names exist.
                delete $p{field}
                    if defined $p{field} && !grep { $_ eq $p{field} } @{ $fields || [] };
                my $ok = 1;
                $text =~ s{\{(\w+)\}}{ defined $p{$1} ? $p{$1} : do { $ok = 0; '' } }ge;
                $text = $generic unless $ok;
            }
            else { $text = $generic }
            $banner = qq(<p class="form-status form-status-error" role="alert">) . _tt_inert( _esc_html($text) ) . qq(</p>\n);
        }
    }
    return $banner;
}

# SM1012 S5: ONE RENDERER PER FIELD KIND, IN THE ORDER THEY WIN. A field is
# rendered by the first kind whose rule it carries - `file` before `textarea`,
# `textarea` before the choosers - which is the order the if/elsif chain this
# replaces tested them in; a field with none of them is an <input>
# (_form_field_input). A new kind is a row here and a sub above. (`select:`,
# `radio:` and `checklist:` each take the rest of the line, so a field carries
# at most one of them and their order among themselves is never seen.)
#
# SM401: radio and checklist. A select hides its options behind a click,
# which is right for a long list and wrong for a page of short questions
# answered in sequence - every option stays visible and a mis-pick is
# obvious rather than silent.
my @FORM_FIELD_KINDS = (
    [ file      => \&_form_field_file ],
    [ textarea  => \&_form_field_textarea ],
    [ select    => \&_form_field_select ],
    [ radio     => \&_form_field_radio ],
    [ checklist => \&_form_field_checklist ],
);

sub _render_form {
    my ( $body, $meta ) = @_;

    my $form_name = $meta->{form} // '';
    unless ($form_name) {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'form block found but no form key in front matter' );
        return "<!-- lazysite: form: key required in front matter -->\n";
    }

    # SM252: the timing token is PER-VISITOR data and this is a PER-PAGE cache,
    # which is the whole mismatch. Minting here bakes one timestamp into the
    # cached HTML and hands it to every visitor until the page next renders, so
    # the minimum-dwell check passes unconditionally (the interval elapsed before
    # anyone loaded the page) and the two-hour expiry can be spent before a
    # visitor arrives - too weak for what it exists to catch and too strict for
    # what it should let through, at the same time.
    #
    # So emit a PLACEHOLDER and let output_page mint the real token on every
    # response. The expensive part of the render still caches; only these two
    # values are per-request. No JavaScript, no extra request, no cookie - the
    # published stance is that forms work without any of them.
    my $ts = $FORM_TS_PLACEHOLDER;
    my $tk = $FORM_TK_PLACEHOLDER;

    # SM098: a '--- step ---' line (optionally '--- step: Title ---') splits the
    # form into wizard steps. Fields accumulate into the current step; without any
    # delimiter there is a single step = the classic single-page form (unchanged).
    my @steps = ( { title => '', fields => [] } );
    my @server_rules;    # SM934 FV1: what the handler will hold a submission to
    for my $line ( split /\n/, $body ) {
        if ( $line =~ /^\s*-{3,}\s*step\b\s*:?\s*(.*?)\s*-{3,}\s*$/i ) {
            push @steps, { title => $1, fields => [] };
            next;
        }
        $line =~ s/^\s+|\s+$//g;
        next unless length $line;

        my ( $name, $label, $rules_str ) = split /\s*\|\s*/, $line, 3;
        $name      //= '';
        $label     //= '';
        $rules_str //= '';
        $name  =~ s/^\s+|\s+$//g;
        $label =~ s/^\s+|\s+$//g;

        next unless length $name;

        if ( $name eq 'submit' ) {
            push @{ $steps[-1]{fields} }, qq(  <div class="form-field form-submit">\n)
                . qq(    <button type="submit">$label</button>\n)
                . qq(  </div>\n);
            next;
        }

        # The rules, as tokens and then as the field's rules (SM1012 S1, S2).
        my @rule_tokens = _form_rule_tokens( $rules_str, $name );
        my %rules       = _form_rules_from_tokens(@rule_tokens);
        my $ph_attr     = '';
        if ( defined $rules{placeholder} ) {
            my $ph = _esc_attr( $rules{placeholder} );
            $ph_attr = qq( placeholder="$ph");
        }

        # SM856: THE FIELD CAN CARRY A VALUE, and where it comes from is gated.
        #
        # `value:"..."` is a literal default. `prefill:<param>` takes the value of
        # a query parameter and is REFUSED unless the page declares that
        # parameter in `query_params:` - the allowlist is the gate, so prefill
        # reaches nothing the page has not already admitted, and an undeclared
        # parameter is an author error said out loud rather than an empty field
        # nobody can explain. A parameter that IS declared but absent from this
        # request leaves the literal standing.
        #
        # Escaped with _esc_attr, as placeholder, pattern and accept are: the
        # value is visitor-controllable and must not be able to leave the
        # attribute. It is also not a trust elevation - a prefilled value proves
        # nothing that a typed one would not.
        my $val_attr = '';
        my $value    = _form_field_value( $name, $meta, %rules );    # SM1012 S3

        # SM869: ONE INPUT STATE, AND THIS SINK ESCAPES IT, UNCONDITIONALLY.
        #
        # SM868 escaped by SOURCE - a `value:` literal escaped, a query value
        # passed through because parse_query_string had already escaped it for
        # the stash. Correct, and the sink could not verify its own safety: it
        # rested on a substitution in another function written for another
        # consumer. Now %RENDER_QUERY is raw, a literal is raw, and both are
        # escaped here for this context. (SM868's lesson stays in the tests: a
        # fixture of alphanumerics is a fixed point of escaping, so the values
        # that pin this carry & < > " ' - t/unit/processor/80 and 88.)
        #
        # The context is an attribute, or textarea text, inside a body that TT
        # renders NEXT - so the value is made TT-inert as well as HTML-escaped.
        # A visitor's `[% ... %]` used to run here. It also means a `[%` in a
        # `value:` literal is now shown as typed rather than evaluated: the rule
        # takes TEXT.
        if ( defined $value && length $value ) {
            # _esc_html rather than _esc_attr: the form's HTML passes through the
            # Markdown converter before TT, and a bare `<` inside an attribute is
            # one more thing for it to misread. Escaping all five is valid in an
            # attribute and displays the same.
            my $v = _tt_inert( _esc_html($value) );
            $val_attr = qq( value="$v");
        }

        my $req_attr = $rules{required} ? ' required' : '';
        my $max      = $rules{max} || 1000;
        my $req_mark = $rules{required}
            ? ' <span class="required">*</span>' : '';

        # SM934 FV1: THE EFFECTIVE PATTERN, COMPUTED ONCE.
        #
        # Hoisted out of the text-input branch below because the submit-time
        # sidecar needs the same value the browser is given, and the tel default
        # is part of that value. Two expressions for "which pattern is in force"
        # would be two answers the day one of them changed - and the whole point
        # of the sidecar is that the server enforces exactly what was rendered.
        my $eff_pat = $rules{pattern};
        $eff_pat = '[0-9\\s\\(\\)\\+\\.\\-]{6,30}'
            if !defined $eff_pat && ( $rules{type} // '' ) eq 'tel';

        push @server_rules, _form_server_rule( $name, $max, $eff_pat, %rules ); # SM1012 S4

        # The field's markup: the first kind in @FORM_FIELD_KINDS whose rule it
        # carries renders it, and a field with none of them is an <input>.
        my $render = \&_form_field_input;
        for my $kind (@FORM_FIELD_KINDS) {
            if ( $rules{ $kind->[0] } ) { $render = $kind->[1]; last }
        }
        my $field_html
            = $render->( $name, $value, $max, $req_attr, $ph_attr, $val_attr, $eff_pat, %rules );

        push @{ $steps[-1]{fields} }, qq(  <div class="form-field">\n)
            . qq(    <label for="$name">$label$req_mark</label>\n)
            . $field_html
            . qq(  </div>\n);
    }

    _write_form_rules( $form_name, \@server_rules );    # SM934 FV1

    # Drop steps that ended up with no fields (e.g. a leading delimiter).
    @steps = grep { @{ $_->{fields} } } @steps;
    @steps = ( { title => '', fields => [] } ) unless @steps;
    my $multi = @steps > 1;

    my $all_fields = join( '', map { @{ $_->{fields} } } @steps );

    # A form with a file input must POST as multipart/form-data, or the browser
    # sends only the filename, not the bytes.
    my $enctype = $all_fields =~ /type="file"/
        ? qq(\n      enctype="multipart/form-data") : '';

    # SM098: assemble the fields region. Single step = flat (unchanged). Multi =
    # one <fieldset> per step + progress + Back/Next nav; a script shows one step
    # at a time and validates it before advancing. Without JS every step shows and
    # the form still submits (progressive enhancement).
    my ( $fields_html, $multistep_attr, $step_css, $extra_script ) = ( '', '', '', '' );
    if ($multi) {
        $multistep_attr = ' data-multistep="1"';
        my $n = scalar @steps;
        $fields_html = qq(  <div class="lsf-progress" aria-hidden="true">Step )
            . qq(<span class="lsf-cur">1</span> of $n</div>\n);
        for my $i ( 0 .. $#steps ) {
            my $legend = length $steps[$i]{title}
                ? qq(    <legend>$steps[$i]{title}</legend>\n) : '';
            $fields_html .= qq(  <fieldset class="lsf-step" data-step="$i">\n)
                . $legend . join( '', @{ $steps[$i]{fields} } ) . qq(  </fieldset>\n);
        }
        $fields_html .= qq(  <div class="lsf-nav">\n)
            . qq(    <button type="button" class="lsf-back">Back</button>\n)
            . qq(    <button type="button" class="lsf-next">Next</button>\n)
            . qq(  </div>\n);
        $step_css     = _form_step_css();
        $extra_script = _form_step_script($form_name);
    }
    else {
        $fields_html = join( '', @{ $steps[0]{fields} } );
    }

    # SM415: the page's own path rides as a hidden field, so a no-JS post can
    # be redirected BACK here with its outcome - the login pattern, which the
    # forms were missing. And when this request's query string carries that
    # outcome (form=<this form>&outcome=...), it renders as a banner above
    # the form: ok as success, anything else as the user-safe refusal text
    # the handler chose to show. Escaped, capped, and only for THIS form's
    # name, so a page with two forms banners the right one.
    my $page = $ENV{REDIRECT_URL} // '';
    $page = '' unless $page =~ m{\A/} && $page !~ m{\A//} && $page !~ /[\r\n<>"]/;
    my $page_esc = $page;
    $page_esc =~ s/&/&amp;/g;
    my $banner = _form_outcome_banner( $form_name, [ map { $_->{name} } grep { ref $_ eq 'HASH' && defined $_->{name} } @server_rules ] ); # SM1012 S6
    return <<"END_FORM";
$banner$step_css<form method="POST"
      action="/cgi-bin/form-handler.pl"$enctype
      class="lazysite-form"
      data-form="$form_name"$multistep_attr>
  <input type="hidden" name="_form" value="$form_name">
  <input type="hidden" name="_page" value="$page_esc">
  <input type="hidden" name="_ts" value="$ts">
  <input type="hidden" name="_tk" value="$tk">
  <div style="position:absolute;left:-9999px;top:-9999px;"
       aria-hidden="true">
    <label for="_hp">Leave this empty</label>
    <input type="text" name="_hp" id="_hp" value=""
           tabindex="-1" autocomplete="off">
  </div>
$fields_html  <div class="form-status" aria-live="polite"></div>
</form>
$extra_script
END_FORM
}

# SM098: inline CSS for a multi-step form. Without the JS-added `lsf-js` class,
# every step shows and the nav is hidden (progressive enhancement); with it, only
# the active step shows and the Back/Next nav appears.
# SM098 / SM352: the multi-step form's progressive-enhancement CSS moved to
# /assets/lazysite-chrome.css. It was an inline <style> block on every page
# carrying a multi-step form, which is one of the ten entries in t/lint/56's
# inventory and one of the reasons no Content-Security-Policy worth setting
# fits this engine.
#
# The rules themselves are unchanged and still do the same job: without the
# JS-added `lsf-js` class every step shows and the nav is hidden, so a visitor
# with no JavaScript gets one long usable form rather than a dead one.
#
# Returns the LINK now rather than the style. Kept as a function, and kept
# emitting something, because the call sites want one thing at one point and a
# caller that has to know whether to emit is a caller that will get it wrong.
sub _form_step_css {
    # The version is resolved here rather than left as a TT tag: this string is
    # spliced into rendered output, which TT has already been through.
    return '<link rel="stylesheet" href="/assets/lazysite-chrome.css?v='
        . _lazysite_version() . '">';
}

# SM098: the step-navigation script for a multi-step form. Shows one step at a
# time, validates the visible step (native constraint API) before advancing, and
# keeps the Back/Next/submit affordances in sync. The final step exposes the
# authored submit button; the existing submit handler posts the whole form once.
# SM098 / SM352: the multi-step navigation moved to
# /assets/lazysite-chrome.js, together with the submit handler.
#
# NEITHER NEEDED THE FORM NAME. Both used it only to SELECT the form, and
# `data-form` is already on the element - so iterating `.lazysite-form` does the
# same job for one form or five, and the name stops being a reason to generate
# code per form. That is what let them join the bundle instead of needing a
# nonce or a per-page hash.
#
# The function survives, returning nothing, because the caller emits whatever it
# returns at the point a multi-step form is rendered. Removing the call site
# instead would mean the caller deciding whether a form is multi-step, which is
# a question this already answers.
sub _form_step_script { return '' }

sub convert_fenced_divs {
    my ($text) = @_;

    $text =~ s{
        ^(:::[ \t]+(\S+)[^\n]*)\n  # opening ::: classname [rest of line]
        (.*?)                       # content
        ^:::[ \t]*\n                # closing :::
    }{
        my $opening = $1;
        my $class   = $2;
        my $body    = $3;
        # Skip 'include' and 'oembed' - handled by dedicated converters
        if ( $class eq 'include' || $class eq 'oembed' ) {
            "$opening\n${body}:::\n";
        }
        # Reject class names containing unsafe characters (S4)
        # Valid: word chars and hyphens only, must start with a word char
        elsif ( $class =~ /\A[\w][\w-]*\z/ ) {
            # Render the body's Markdown (block AND inline) so headings/lists
            # inside a box don't leak as literal '##' - Text::MultiMarkdown
            # otherwise treats <div> content as verbatim HTML. Skip pre-render if
            # the body nests another fenced block (include/oembed/form) that the
            # later pipeline passes must still see.
            my $inner = ( $body =~ /^:::/m ) ? $body : convert_md($body);
            qq(<div class="$class">\n${inner}</div>\n);
        }
        else {
            log_event('WARN', $ENV{REDIRECT_URL} // '-', 'fenced div rejected unsafe class', class => $class);
            $body;
        }
    }gsmxe;

    return $text;
}

1;
