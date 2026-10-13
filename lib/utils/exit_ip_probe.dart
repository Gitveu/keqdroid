// без особого правила запрос шёл бы по правилам пользователя, и при всё остальное напрямую флаг показывал домашний адрес.
// сам сайт Cloudflare, не one.one.one.one: тот ещё и DNS, и правило задело бы Частный DNS Android
const kExitIpProbeHost = 'www.cloudflare.com';

const kExitIpProbeUrl = 'https://$kExitIpProbeHost/cdn-cgi/trace';
