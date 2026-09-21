# PiTi iOS V1 — 21 Eylül 2026

Durum: geliştirme başlangıcı. App Store'a gönderilebilir veya TestFlight'ta
kurulabilir bir sürüm henüz yok. Ana web yayını ve canlı veritabanı değiştirilmedi.

## Tamamlanan kaynak çalışması

- Swift/WKWebView istemcisi; adres çubuğu yok, native hata/yeniden dene ekranı,
  güvenli alan ve klavye davranışı; normal web kullanıcıları için etkisiz JS köprüsü.
- Açık kullanıcı eylemiyle bildirim izni; iPhone ayarlarına yönlendirme.
- Profilde mesaj, seans, görev ve ödeme bildirim tercihleri. Hesap genelinde
  sunucuda tutulur; kapatılan türün bekleyen bildirimleri temizlenir, yeni
  bildirimler ve gönderim kuyruğu sunucuda filtrelenir. Gönderilmiş bildirimler
  geri alınamaz. Tercihler iPhone izinlerini değiştirmez.
- Native APNs cihaz kaydı, oturumla eşleştirme, çıkışta devre dışı bırakma.
- Mesaj, görev, seans talebi/sonucu/zaman değişikliği ve ödeme değişikliği için
  sunucudan belirlenen alıcılar; mesaj içeriği ve sağlık bilgisi kilit ekranına gitmez.
- Cihaz bazında kuyruk, yeniden deneme, geçersiz cihazı kapatma ve süre aşımı.
- Bildirime dokununca giriş tamamlanana kadar bekleme; yanlış hesabın bildirimini
  açmama; uygun takvim gününe, müşteri sohbetine veya ödeme ekranına yönlendirme.
- Debug, TestFlight Staging ve Production ayrı yapılandırmalar. TestFlight
  staging de APNs production taşımasını kullanır; uygulama ortamı staging kalır.
- Push varsayılan olarak KAPALI. Migration/scheduler/APNs yapılandırması canlıda
  uygulanmadı. Native dosya/fotoğraf seçimi mevcut web input'larını kullanır;
  gerçek cihazda kamera, galeri, PDF dekont ve ses izin testleri açık.

## V1 tamamlanma kapıları

| Kapı | Durum / kabul şartı |
| --- | --- |
| Apple Developer hesabı | Hesabın varlığı ve Individual/Organization türü bilinmiyor. Marka/satıcı adı kararı ve gerekli yetki kullanıcıda. |
| İmzalama | Team ID, doğrulanmış Bundle ID, push entitlement, sertifika/provisioning ve APNs anahtarı henüz ayarlanmadı. Anahtarlar sohbete veya Git'e konmaz. |
| Ayrı STAGING | workers.dev CANLI ile aynı veriyi kullanıyor. Staging URL boş bırakıldı; canlıya otomatik geçiş yok. Frontend ve backend birlikte ayrılmalı. |
| Xcode | GitHub macOS üzerinde Debug ve Release imzasız simülatör derlemeleri geçti; Staging Bundle ID/APNs ayrımı doğrulandı. Simülatör derlemesi gerçek cihaz testi değildir. |
| Bildirimler | Gerçek cihazda foreground/background/cold start, izin reddi, logout, token değişimi, iki cihaz, iki kullanıcı ve demo izolasyonu doğrulanmalı. |
| Kalan push olayları | Yaklaşan seans zamanlayıcısı, gecikeceğim olayı ve PT seçili müşterilere manuel bildirim tamamlanmalı. Kategori tercihleri kodda ve yerel testlerde tamamlandı; staging ve gerçek cihaz doğrulaması açık. |
| Hesap silme | Sadece talep tablosu yeterli DEĞİL. Kullanıcı uygulama içinden başlatmalı; Auth, ilişkili kayıtlar, Storage ve saklama istisnaları gerçekten işlenmeli; tamamlanma bildirilmeli. Yapılmadan gönderilmez. |
| Gizlilik | Erişilebilir gerçek gizlilik ve destek URL'leri; sorumlu kişi/şirket bilgileri; sağlık/ölçüm, fotoğraf, mesaj, ödeme, cihaz tanımlayıcıları ve saklama beyanları gerçek uygulamayla eşleşmeli. |
| Mesajlaşma güvenliği | Bildir/engelle, uygunsuz içerik yönetimi ve erişilebilir destek kanalı değerlendirilip tamamlanmalı (1.2). |
| Ödeme modeli | Yüz yüze PT hizmetleri ile uygulama özelliği/dijital abonelik ücretini ayır. Fiziksel PT hizmeti EFT kaydı, dijital premium özellik satışıyla aynı sayılmaz. |
| İnceleme erişimi | Apple için PT ve müşteri test hesapları; gerçek kullanıcı verisi yok; backend çalışır; tüm görünür özellikler denenebilir. |
| App Store metaverisi | Nihai ikon, gerçek cihaz ekran görüntüleri, yaş derecesi, kategori, açıklama, App Privacy, ihracat/şifreleme beyanı doğrulanmalı. Geçici başlangıç ikonu final tasarım değildir. |
| Yayın onayı | Önce test/inceleme, sonra Erkan'ın açık production onayı. Bu dal main ile birleştirilmedi. |

## Apple incelemesi

Apple onayı garanti edilemez. Native bildirim eklemek tek başına 4.2 onayı
sağlamaz; uygulamanın bütünsel faydası, kalitesi ve tamamlanmışlığı değerlendirilir.
Web içeriğini sonradan incelemeyi aşmak veya gizli yeni işlevler açmak için
değiştirmeyiz. Önemli native/ürün değişiklikleri yeni inceleme gerektirebilir.

Kaynaklar (21 Eylül 2026):
- [App Review Guidelines — 4.2, 2.1, 1.2, 3.1 ve 5.1](https://developer.apple.com/app-store/review/guidelines/)
- [Uygulama içinden hesap silme](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
- [APNs kaydı](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
- [Supabase push yaklaşımı](https://supabase.com/docs/guides/functions/examples/push-notifications)

## Test kapsamı ve sınırlar

Node testleri göndericiyi taklit APNs yanıtlarıyla ve JS köprüsünü izole şekilde
test eder. PGlite testi gerçek PostgreSQL motorunda küçük geçici bir şemaya
migration uygular: RLS, yetkiler, oturum, alıcı, tekrar önleme, lease ve hesap
değişimi test edilir. Bu, gerçek Supabase projesi ve tüm mevcut migration/admin
script geçmişinin uçtan uca testi değildir. Canlı veritabanına bağlanmaz.

Yeni Node push testleri (9 test), geçici Postgres testi ve mevcut self-password,
demo-isolation, offline-guard testleri yerelde geçti. Mevcut
`account-transition.test.cjs` içindeki 4 hata, eksik `navigator` test taklidi
yüzünden oluşuyor; değiştirilmemiş `195fb2e` tabanında da aynı hatalar doğrulandı.
Bu test dosyası değiştirilmedi ve bütün testler geçti iddiası yapılmıyor.

Ek olarak dört bildirim tercih ekranı testi ve ayrı Postgres tercih testi geçti:
iki cihaz, hesap izolasyonu, geçersiz oturum, yetki/RLS, kategori filtreleme,
bekleyen kuyruğu temizleme ve yeniden açınca eski bildirimleri göndermeme.
Hesap silme bağımlılıkları `account-deletion-scope.md` dosyasında kayıtlı;
henüz çalışan bir hesap silme servisi veya ekranı eklenmedi.

Native derleme kanıtı: [GitHub Actions #1](https://github.com/ErkanYardibi/Piti-online/actions/runs/35635622637).
Bu çalıştırma APNs'e gerçek bildirim göndermedi ve IPA/TestFlight oluşturmadı.
Ana dalda sonradan eklenen mobil ana sayfa ve sohbet gezinme iyileştirmeleri
(`565b01c`'ye kadar) iOS dalına çakışmasız alındı; bu işlem ana dalı değiştirmedi.
