package ms.rohde.wifpoc.servicer;

import java.util.List;
import org.jspecify.annotations.Nullable;
import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtClaimNames;
import org.springframework.security.oauth2.jwt.JwtClaimValidator;
import org.springframework.security.oauth2.jwt.JwtValidators;

/** Validation rules every access token must pass before its scopes are considered. */
final class AccessTokenValidators {

    private static final String TOKEN_TYPE_CLAIM = "typ";
    private static final String ACCESS_TOKEN_TYPE = "Bearer";
    private static final String CLIENT_ID_CLAIM = "azp";

    private AccessTokenValidators() {
    }

    /**
     * Default timestamp checks (60 s clock skew), an exact issuer match, an audience of exactly
     * {@code audience} (a token addressed to several services is refused, so no other service can
     * replay it here), the access token type {@code Bearer} and a present client ID ({@code azp}).
     */
    static OAuth2TokenValidator<Jwt> forIssuerAndAudience(String issuer, String audience) {
        OAuth2TokenValidator<Jwt> soleAudience = new JwtClaimValidator<@Nullable List<String>>(
                JwtClaimNames.AUD, aud -> aud != null && aud.equals(List.of(audience)));
        OAuth2TokenValidator<Jwt> accessTokenType = new JwtClaimValidator<@Nullable String>(
                TOKEN_TYPE_CLAIM, ACCESS_TOKEN_TYPE::equals);
        OAuth2TokenValidator<Jwt> clientIdPresent = new JwtClaimValidator<@Nullable String>(
                CLIENT_ID_CLAIM, clientId -> clientId != null && !clientId.isBlank());
        return new DelegatingOAuth2TokenValidator<>(List.of(
                JwtValidators.createDefaultWithIssuer(issuer), soleAudience, accessTokenType, clientIdPresent));
    }
}
