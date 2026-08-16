/**
 * @file lloraclereceiptpublisher.h
 * @brief Darwin no-replace publisher for developer-only OpenGL oracle receipts.
 *
 * $LicenseInfo:firstyear=2026&license=viewerlgpl$
 * Second Life Viewer Source Code
 * Copyright (C) 2026, Linden Research, Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation;
 * version 2.1 of the License only.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 * $/LicenseInfo$
 */

#ifndef LL_LLORACLERECEIPTPUBLISHER_H
#define LL_LLORACLERECEIPTPUBLISHER_H

#include <string>

namespace LLOpenGLOracleReceiptPublisher
{

// Publishes document at an absolute, previously absent path. Every ancestor
// is traversed descriptor-relatively without following symlinks. The final
// leaf is cloned atomically from an unlinked, synchronized staging descriptor;
// it is never replaced and this function intentionally has no weaker fallback.
bool publishNoReplace(const std::string& target_path, const std::string& document);

#if defined(LL_TEST_lloracleloginnavigation) || defined(LL_TEST_lloracleloginvisualprofile)
// Standalone helper tests observe the descriptor-anchored phases without
// making the publication mechanics part of a viewer runtime API.
using PublicationTestHook = void (*)();
void setPublicationTestHook(PublicationTestHook hook);
#endif

} // namespace LLOpenGLOracleReceiptPublisher

#endif // LL_LLORACLERECEIPTPUBLISHER_H
