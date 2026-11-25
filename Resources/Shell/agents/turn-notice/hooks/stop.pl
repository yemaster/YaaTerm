use strict;
use warnings;
use utf8;
use JSON::PP;
use Encode qw(encode_utf8);
use MIME::Base64 qw(encode_base64);

my $tty = $ENV{YAATERM_NOTICE_TTY} // '';
my $agent = $ENV{YAATERM_NOTICE_AGENT} // '';
exit 0 unless -c $tty && $agent =~ /\A(?:claude|qodercn|qoder-cn|qoderclicn|qodercli)\z/;

# Read one bounded JSON event. Older agents may omit the final reply.
my $encoded = '';
unless (-t STDIN) {
    local $/ = \524289;
    my $input = <STDIN>;
    if (defined $input && length($input) <= 524288) {
        my $event = eval { decode_json($input) };
        if (ref($event) eq 'HASH' && defined $event->{last_assistant_message} && !ref($event->{last_assistant_message})) {
            my $reply = $event->{last_assistant_message};
            # Keep a closing summary even when a long answer starts with code or background.
            if (length($reply) > 360) {
                $reply =~ s{^[ \t]*(\x60{3,}|~{3,})[^\n]*\n.*?(?:^[ \t]*\1[ \t]*$|\z)}{}gms;
                if ($reply =~ /^[ \t]*(?:\#{1,6}[ \t]+)?(?:\*\*)?(?:任务总结|总结|摘要|summary|tl;dr)(?:\*\*)?[ \t]*(?:[:：]|$)/im) {
                    $reply = substr($reply, $-[0], 360);
                }
            }
            $encoded = encode_base64(encode_utf8(substr($reply, 0, 360)), '');
        }
    }
}
open my $out, '>:raw', $tty or exit 0;
print {$out} "\e]777;yaaterm-turn;$agent;$encoded\a";
