use strict;
use warnings;
use utf8;
use JSON::PP qw(decode_json);
use Encode qw(decode);
binmode STDIN, ':raw';
binmode STDOUT, ':encoding(UTF-8)';
$| = 1;
my $prompt = decode('UTF-8', shift // '');
my $stream = (shift // '') ne '--no-stream';
# Preserve text and SGR colors, without replaying the shell's title or cursor controls.
$prompt =~ s{\e(?:\][^\a\e]*(?:\a|\e\\)|[PX^_].*?\e\\)}{}gs;
$prompt =~ s{(\e\[[0-9;:]*m)|\e\[[0-?]*[ -/]*[\@-~]|[^\P{Cc}\n\t]}{$1 // ''}ge;

sub clean {
    my ($text) = @_;
    $text =~ s/[\p{Cc}\p{Bidi_Control}]/($& eq "\n" || $& eq "\t") ? $& : '�'/ge;
    return $text;
}

my (@emitted, $block_open, $needs_newline);
sub end_block {
    print "\n" if $needs_newline;
    $block_open = $needs_newline = 0;
}

sub fragment {
    my ($text) = @_;
    return unless defined $text && !ref $text && length $text;
    if (!$block_open) { push @emitted, 0; $block_open=1; }
    $emitted[-1] += length $text;
    print clean($text);
    $needs_newline = substr($text,-1) ne "\n";
}

sub line {
    my ($text) = @_;
    return unless defined $text && !ref $text && length $text;
    end_block();
    print clean($text), (substr($text,-1) eq "\n" ? '' : "\n");
}

sub tool_call {
    my ($command, $name) = @_;
    if (defined $command && !ref $command && length $command) {
        end_block();
        print $prompt;
        line($command);
    } else {
        line($name);
    }
}

sub content {
    my ($parts, $assistant) = @_;
    if (!ref $parts) { line($parts); return; }
    return unless ref $parts eq 'ARRAY';
    for my $part (@$parts) {
        if (!ref $part) { line($part); next; }
        next unless ref $part eq 'HASH';
        my $type=$part->{type} // '';
        if ($type eq 'text') {
            my $text=$part->{text};
            if ($assistant && @emitted && defined $text && !ref $text) {
                my $offset=shift @emitted;
                $text=$offset<length($text) ? substr($text,$offset) : '';
                end_block();
            }
            line($text);
        }
        elsif ($type eq 'tool_use') {
            my $args=$part->{input};
            my $command=ref $args eq 'HASH' ? $args->{command} : undef;
            tool_call($command, $part->{name});
        }
        elsif ($type eq 'tool_result') { content($part->{content}); }
    }
}

my $last_text;
sub event {
    my ($raw)=@_;
    my $item=eval { decode_json($raw) };
    unless (ref $item eq 'HASH') { line(decode('UTF-8',$raw)); return; }
    my $type=$item->{type} // '';
    my $message=$item->{message};
    if ($type eq 'stream_event' || $type eq 'message_update') {
        return unless $stream;
        my $part=$type eq 'stream_event' ? $item->{event} : $item->{assistantMessageEvent};
        return unless ref $part eq 'HASH';
        my $kind=$part->{type} // '';
        if ($kind eq 'message_start') { end_block(); @emitted=(); }
        elsif ($kind eq 'text_delta') { fragment($part->{delta}); }
        elsif ($kind eq 'content_block_delta' && ref $part->{delta} eq 'HASH' && ($part->{delta}{type}//'') eq 'text_delta') {
            fragment($part->{delta}{text});
        }
        elsif ($kind eq 'content_block_stop' || $kind eq 'text_end') { end_block(); }
        return;
    }
    if (($type eq 'assistant' || $type eq 'user' || $type eq 'message_end') && ref $message eq 'HASH') {
        my $parts=$message->{content};
        if ($type eq 'user') {
            content([grep { ref $_ eq 'HASH' && ($_->{type}//'') eq 'tool_result' } @$parts]) if ref $parts eq 'ARRAY';
        } elsif ($type ne 'message_end' || ($message->{role}//'') eq 'assistant') {
            content($parts,1);
            if (ref $parts eq 'ARRAY') {
                my @texts=map { $_->{text}//'' } grep { ref $_ eq 'HASH' && ($_->{type}//'') eq 'text' } @$parts;
                $last_text=join("\n",@texts) if @texts;
            }
        }
    } elsif ($type eq 'tool_execution_start') {
        my $args=$item->{args};
        my $cmd=ref $args eq 'HASH' ? $args->{command} : undef;
        tool_call($cmd, $item->{toolName});
    } elsif ($type eq 'tool_execution_end' && ref $item->{result} eq 'HASH') {
        content($item->{result}{content});
    } elsif ($type eq 'result') {
        my $result=$item->{result};
        line($result) if !defined $last_text || !defined $result || ref $result || $result ne $last_text;
        content($item->{errors}) if ref $item->{errors} eq 'ARRAY';
    } elsif ($type eq 'error') {
        my $error=$item->{error};
        line(ref $error eq 'HASH' ? $error->{message} : $error // $message);
    }
}

# Bound a partial NDJSON record, including when the provider emits binary attachments.
my ($pending,$skip)=('',0);
while (sysread(STDIN,my $block,16384)) {
    while (length $block) {
        my $end=index($block,"\n");
        my $chunk=$end<0 ? $block : substr($block,0,$end);
        if (!$skip && length($pending)+length($chunk)>262144) {
            $skip=1; $pending=''; line('（过长的事件已省略）');
        }
        $pending.=$chunk unless $skip;
        last if $end<0;
        event($pending) if !$skip && length $pending;
        $pending=''; $skip=0; substr($block,0,$end+1,'');
    }
}
event($pending) if !$skip && length $pending;
end_block();
