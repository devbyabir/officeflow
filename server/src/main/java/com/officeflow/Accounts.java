package com.officeflow;

import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;

/** Role behavior stays in the account types rather than in the browser. */
public final class Accounts {
  private Accounts() {}

  public abstract static class Account {
    private final String id;

    protected Account(String id) {
      this.id = id;
    }

    public final String id() {
      return id;
    }

    public abstract String role();

    public final boolean isAdmin() {
      return role().equals("admin");
    }
  }

  public static final class Administrator extends Account {
    public Administrator(String id) {
      super(id);
    }

    @Override
    public String role() {
      return "admin";
    }
  }

  public static final class Teacher extends Account {
    public Teacher(String id) {
      super(id);
    }

    @Override
    public String role() {
      return "teacher";
    }
  }

  /** The single password policy for chosen, reset and initial administrator passwords. */
  public static void validatePassword(String password) {
    if (password.length() < 12 || password.length() > 120 || password.isBlank())
      throw new IllegalArgumentException("Use a password with 12–120 characters.");
  }

  // No 0/O, 1/l/I, so a temporary password can be read aloud or copied by hand.
  private static final String TEMPORARY_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";

  /** A random temporary password such as {@code k7mq-x2pd-9wfn-r4ta} (19 characters). */
  public static String temporaryPassword() {
    SecureRandom random = new SecureRandom();
    StringBuilder result = new StringBuilder();
    for (int i = 0; i < 16; i++) {
      if (i > 0 && i % 4 == 0) result.append('-');
      result.append(TEMPORARY_ALPHABET.charAt(random.nextInt(TEMPORARY_ALPHABET.length())));
    }
    return result.toString();
  }

  public static String hash(char[] password) {
    byte[] salt = new byte[16];
    new SecureRandom().nextBytes(salt);
    return Base64.getEncoder().encodeToString(salt) + ":" + derive(password, salt);
  }

  public static boolean matches(char[] password, String stored) {
    if (stored == null) return false;
    String[] parts = stored.split(":", 2);
    if (parts.length != 2) return false;
    byte[] expected = Base64.getDecoder().decode(parts[1]);
    byte[] actual =
        Base64.getDecoder().decode(derive(password, Base64.getDecoder().decode(parts[0])));
    return MessageDigest.isEqual(expected, actual);
  }

  private static String derive(char[] password, byte[] salt) {
    PBEKeySpec spec = new PBEKeySpec(password, salt, 210_000, 256);
    try {
      return Base64.getEncoder()
          .encodeToString(
              SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
                  .generateSecret(spec)
                  .getEncoded());
    } catch (java.security.GeneralSecurityException exception) {
      throw new IllegalStateException("Password hashing is unavailable", exception);
    } finally {
      spec.clearPassword();
    }
  }
}
