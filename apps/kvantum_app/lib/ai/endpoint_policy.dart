import 'dart:io' show InternetAddress, InternetAddressType;

/// Verdict about the address of the "custom" (OpenAI-compatible) provider.
class EndpointCheck {
  const EndpointCheck._({this.error, this.warning});

  /// Why the address cannot be used (Hungarian, shown to the user).
  final String? error;

  /// The address works, but the user should know something.
  final String? warning;

  bool get ok => error == null;

  static const accepted = EndpointCheck._();
}

/// Where the API key and the prompts may be sent. A public server needs
/// https; plain http is only for the user's own machine or home network
/// (typically a local Ollama), and even then the user is told it is not
/// encrypted. An address with a user name or password in it is refused.
EndpointCheck checkCustomEndpoint(String raw) {
  final text = raw.trim();
  final uri = Uri.tryParse(text);
  if (text.isEmpty || uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return const EndpointCheck._(
      error:
          'Ez nem érvényes cím. Írd teljesen, pl. https://api.example.com/v1',
    );
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    return const EndpointCheck._(
      error: 'A cím http:// vagy https:// kezdetű legyen.',
    );
  }
  if (uri.userInfo.isNotEmpty) {
    return const EndpointCheck._(
      error: 'A cím ne tartalmazzon felhasználónevet vagy jelszót.',
    );
  }
  if (scheme == 'https') return EndpointCheck.accepted;
  if (isPrivateHost(uri.host)) {
    return const EndpointCheck._(
      warning: 'Titkosítatlan (http) kapcsolat: csak a saját gépeden vagy az otthoni hálózatodon használd.',
    );
  }
  return const EndpointCheck._(
    error: 'Nyilvános szerverhez https:// cím kell, különben a kulcsod és az adataid titkosítatlanul mennének át. Saját gépen vagy otthoni hálózaton (pl. http://localhost:11434/v1) az http is engedett.',
  );
}

/// The user's own machine or local network: localhost, loopback, private
/// IPv4 ranges (10/8, 172.16/12, 192.168/16), link-local, IPv6 unique-local,
/// and the names routers/mDNS use (.local, .lan, .home.arpa).
bool isPrivateHost(String host) {
  var h = host.toLowerCase();
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  if (h == 'localhost' || h.endsWith('.localhost')) return true;
  if (h.endsWith('.local') || h.endsWith('.lan') || h.endsWith('.home.arpa')) {
    return true;
  }
  final ip = InternetAddress.tryParse(h);
  if (ip == null) return false;
  if (ip.isLoopback || ip.isLinkLocal) return true;
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }
  return (b[0] & 0xFE) == 0xFC; // fc00::/7
}
