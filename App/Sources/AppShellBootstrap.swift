// File này CỐ TÌNH không làm gì cả.
//
// @main thật (SimplerApp.swift → struct OpenSideloaderApp: App) nằm trong local
// Swift package "OpenSideloaderApp" (thư mục ../Sources/), được link tĩnh vào
// target App này qua project.yml (dependencies: package: OpenSideloaderApp).
// File này chỉ tồn tại vì XcodeGen/Xcode cần ít nhất 1 Swift source file khai
// báo trực tiếp trong target để tạo Compile Sources phase hợp lệ.
//
// Nếu sau này bạn thấy Xcode báo "no @main found" khi build, khả năng cao là
// package chưa được link đúng cách (kiểm tra target → General → Frameworks,
// Libraries, and Embedded Content có "OpenSideloaderApp" chưa).

import OpenSideloaderApp
