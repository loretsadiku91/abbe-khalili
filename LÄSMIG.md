# Abbe Khalili – hemsidan

## Filerna

| Fil | Vad den är |
|---|---|
| `index.html` | Själva hemsidan. Fungerar direkt i demoläge. |
| `databas.sql` | Databasen. Klistras in i Supabase en gång. |
| `mejlmall.html` | Mejlet med koden som kunderna får. |
| `delar/` | Byggdelar som Claude använder. Behöver inte röras. |

## Demoläge

Så länge inställningarna i `index.html` är tomma körs sidan i demoläge:
- Bokningar sparas bara i webbläsaren du använder.
- Koden som annars skickas med mejl eller sms visas på skärmen.
- Längst ner finns knappen "Demo: visa som Abbe", som öppnar adminpanelen.

## Koppla in den riktiga databasen

1. **Skapa ett projekt på supabase.com.** Logga in med GitHub, tryck på New project, döp det till `abbe-khalili` och välj Stockholm som region. Spara databaslösenordet i Lösenord-appen.
2. **Skapa databasen.** Öppna `databas.sql` och ändra de två e-postadresserna längst ner till Abbes och din egen. Gå till SQL Editor → New query, klistra in hela filen och tryck på Run.
3. **Lägg in mejlet med koden.** Gå till Authentication → Emails. Under både "Magic Link" och "Confirm signup": klistra in `mejlmall.html` och skriv ämnesraden *Din kod till Abbe Khalili*.
4. **Skicka två saker till Claude**, från Settings → API: *Project URL* och nyckeln *anon public*. Den hemliga nyckeln, *service_role*, skickas aldrig till någon.
5. Claude lägger in dem i `index.html` och sparar sidan på GitHub.
6. **Gör sidan synlig.** På GitHub: Settings → Pages → Branch: `main` → Save. Efter någon minut finns sidan på `https://loretsadiku91.github.io/abbe-khalili/`.

## Bra att veta

- Supabase egna mejl är begränsade, både i antal per timme och till vilka adresser de når. Det räcker för att du och Abbe ska kunna testa. Innan riktiga kunder bokar kopplas en mejltjänst (Resend) och domänen in.
- Sms-kod kräver en sms-tjänst (46elks). När den finns sätts `sms: true` i `index.html`.
- Swish är en testknapp tills Abbe har avtal om Swish för webbplatser.
- Kontrollen 24 timmar före start körs automatiskt var tionde minut. Om databasfilen skriver att den inte kunde slås på: slå på Cron under Integrations och kör filen igen.
