import ezvcard.*;

public class VCardFuzz {
    public static void fuzzerInitialize() {

    }

    public static void fuzzerTestOneInput(byte[] data) {
        String input = new String(data);
        VCard vcard = Ezvcard.parse(input).first();
    }
}