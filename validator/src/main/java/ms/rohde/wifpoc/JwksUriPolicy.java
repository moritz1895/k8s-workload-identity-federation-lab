package ms.rohde.wifpoc;

import java.net.MalformedURLException;
import java.net.URI;
import java.net.URL;
import java.util.Locale;

/**
 * Accepts the {@code jwks_uri} of a discovery document only on the issuer's own HTTPS origin
 * (scheme, host and port). Keys are thus always loaded from the endpoint whose name the issuer
 * stands for, never from another host that merely holds a certificate of the same CA.
 */
final class JwksUriPolicy {

    private static final String HTTPS = "https";
    private static final int HTTPS_DEFAULT_PORT = 443;

    private JwksUriPolicy() {
    }

    /**
     * Returns the JWKS URL if it lies on the issuer's origin.
     *
     * @throws IllegalStateException if scheme, host or port differ from the issuer's, or the URI
     *                               carries user info
     */
    static URL jwksUrl(String issuer, String jwksUri) throws MalformedURLException {
        URI issuerUri = URI.create(issuer);
        URI candidate = URI.create(jwksUri);
        if (!HTTPS.equalsIgnoreCase(candidate.getScheme())
                || candidate.getRawUserInfo() != null
                || !sameHost(issuerUri, candidate)
                || effectivePort(issuerUri) != effectivePort(candidate)) {
            throw new IllegalStateException(
                    "jwks_uri '" + jwksUri + "' is not on the HTTPS origin of issuer '" + issuer + "'");
        }
        return candidate.toURL();
    }

    private static boolean sameHost(URI issuer, URI candidate) {
        return issuer.getHost() != null && candidate.getHost() != null
                && issuer.getHost().toLowerCase(Locale.ROOT).equals(candidate.getHost().toLowerCase(Locale.ROOT));
    }

    private static int effectivePort(URI uri) {
        return uri.getPort() == -1 ? HTTPS_DEFAULT_PORT : uri.getPort();
    }
}
