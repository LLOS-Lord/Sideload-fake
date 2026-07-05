#ifndef CCommonCryptoShim_h
#define CCommonCryptoShim_h

// Chỉ include CommonCrypto thật của Apple — không có logic gì tự viết ở đây.
// Dùng cho AES-CBC (decrypt_cbc trong AppleGSAClient), vì CryptoKit cố tình
// không expose chế độ CBC trần (chỉ có GCM/ChaChaPoly).
#include <CommonCrypto/CommonCrypto.h>

#endif
