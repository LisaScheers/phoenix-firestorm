#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>

namespace
{
constexpr NSUInteger MAX_VERTEX_ATTRIBUTES = 31;
constexpr NSUInteger MAX_VERTEX_BUFFERS = 31;
constexpr NSUInteger MAX_METAL_BUFFER_INDEX = 30;
constexpr NSUInteger MAX_METAL_TEXTURE_INDEX = 127;
constexpr NSUInteger MAX_METAL_SAMPLER_INDEX = 15;

bool reject(NSString* __autoreleasing* error, NSString* message)
{
    if (error != nullptr)
    {
        *error = message;
    }
    return false;
}

void print_error(NSString* message)
{
    fprintf(stderr, "%s\n", message.UTF8String);
}

bool is_boolean(NSNumber* number)
{
    return CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID();
}

bool unsigned_integer(id value, NSUInteger* result)
{
    if (![value isKindOfClass:[NSNumber class]] || is_boolean(value))
    {
        return false;
    }
    const char* encoding = [value objCType];
    if (std::strcmp(encoding, @encode(float)) == 0
        || std::strcmp(encoding, @encode(double)) == 0)
    {
        return false;
    }

    double numeric = [value doubleValue];
    if (!std::isfinite(numeric) || numeric < 0.0 || std::floor(numeric) != numeric
        || numeric > static_cast<double>(std::numeric_limits<NSUInteger>::max()))
    {
        return false;
    }

    unsigned long long converted = [value unsignedLongLongValue];
    if (static_cast<double>(converted) != numeric)
    {
        return false;
    }
    *result = static_cast<NSUInteger>(converted);
    return true;
}

bool signed_32_integer(id value, std::int32_t* result)
{
    if (![value isKindOfClass:[NSNumber class]] || is_boolean(value))
    {
        return false;
    }
    const char* encoding = [value objCType];
    if (std::strcmp(encoding, @encode(float)) == 0
        || std::strcmp(encoding, @encode(double)) == 0)
    {
        return false;
    }

    double numeric = [value doubleValue];
    if (!std::isfinite(numeric) || std::floor(numeric) != numeric
        || numeric < static_cast<double>(std::numeric_limits<std::int32_t>::min())
        || numeric > static_cast<double>(std::numeric_limits<std::int32_t>::max()))
    {
        return false;
    }
    long long converted = [value longLongValue];
    if (static_cast<double>(converted) != numeric)
    {
        return false;
    }
    *result = static_cast<std::int32_t>(converted);
    return true;
}

bool is_identifier(NSString* value)
{
    if (![value isKindOfClass:[NSString class]] || value.length == 0)
    {
        return false;
    }
    auto valid_initial = [](unichar character) {
        return (character >= 'A' && character <= 'Z')
            || (character >= 'a' && character <= 'z') || character == '_';
    };
    auto valid_subsequent = [&](unichar character) {
        return valid_initial(character) || (character >= '0' && character <= '9');
    };
    if (!valid_initial([value characterAtIndex:0]))
    {
        return false;
    }
    for (NSUInteger index = 1; index < value.length; ++index)
    {
        if (!valid_subsequent([value characterAtIndex:index]))
        {
            return false;
        }
    }
    return true;
}

bool validate_keys(NSDictionary* object,
                   NSArray<NSString*>* required,
                   NSArray<NSString*>* allowed,
                   NSString* path,
    NSString* __autoreleasing* error)
{
    NSSet<NSString*>* allowed_set = [NSSet setWithArray:allowed];
    NSArray* keys = [[object allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (id key in keys)
    {
        if (![key isKindOfClass:[NSString class]] || ![allowed_set containsObject:key])
        {
            return reject(error,
                          [NSString stringWithFormat:@"%@ has unsupported field %@", path, key]);
        }
    }
    for (NSString* key in required)
    {
        if (object[key] == nil)
        {
            return reject(error,
                          [NSString stringWithFormat:@"%@.%@ is required", path, key]);
        }
    }
    return true;
}

NSString* require_string(NSDictionary* object,
                         NSString* key,
                         NSString* path,
                         NSString* __autoreleasing* error)
{
    id value = object[key];
    if (![value isKindOfClass:[NSString class]] || [value length] == 0)
    {
        reject(error,
               [NSString stringWithFormat:@"%@.%@ must be a non-empty string", path, key]);
        return nil;
    }
    return value;
}

NSArray* require_array(NSDictionary* object,
                       NSString* key,
                       NSString* path,
                       NSString* __autoreleasing* error)
{
    id value = object[key];
    if (![value isKindOfClass:[NSArray class]])
    {
        reject(error, [NSString stringWithFormat:@"%@.%@ must be an array", path, key]);
        return nil;
    }
    return value;
}

NSDictionary* require_object(NSDictionary* object,
                             NSString* key,
                             NSString* path,
                             NSString* __autoreleasing* error)
{
    id value = object[key];
    if (![value isKindOfClass:[NSDictionary class]])
    {
        reject(error, [NSString stringWithFormat:@"%@.%@ must be an object", path, key]);
        return nil;
    }
    return value;
}

bool require_unsigned_integer(NSDictionary* object,
                              NSString* key,
                              NSString* path,
                              NSUInteger* result,
                              NSString* __autoreleasing* error)
{
    if (!unsigned_integer(object[key], result))
    {
        return reject(error,
                      [NSString stringWithFormat:@"%@.%@ must be a non-negative integer",
                                                 path,
                                                 key]);
    }
    return true;
}

bool require_boolean(NSDictionary* object,
                     NSString* key,
                     NSString* path,
                     BOOL* result,
                     NSString* __autoreleasing* error)
{
    id value = object[key];
    if (![value isKindOfClass:[NSNumber class]] || !is_boolean(value))
    {
        return reject(error,
                      [NSString stringWithFormat:@"%@.%@ must be a boolean", path, key]);
    }
    *result = [value boolValue];
    return true;
}

MTLPixelFormat pixel_format(NSString* name)
{
    if ([name isEqualToString:@"bgra8unorm"])
    {
        return MTLPixelFormatBGRA8Unorm;
    }
    if ([name isEqualToString:@"rgba8unorm"])
    {
        return MTLPixelFormatRGBA8Unorm;
    }
    if ([name isEqualToString:@"rgba16unorm"])
    {
        return MTLPixelFormatRGBA16Unorm;
    }
    if ([name isEqualToString:@"rgba16float"])
    {
        return MTLPixelFormatRGBA16Float;
    }
    if ([name isEqualToString:@"rg11b10float"])
    {
        return MTLPixelFormatRG11B10Float;
    }
    if ([name isEqualToString:@"depth32float"])
    {
        return MTLPixelFormatDepth32Float;
    }
    return MTLPixelFormatInvalid;
}

struct VertexFormat
{
    MTLVertexFormat format;
    NSUInteger size;
};

VertexFormat vertex_format(NSString* name)
{
    if ([name isEqualToString:@"float"])
    {
        return {MTLVertexFormatFloat, 4};
    }
    if ([name isEqualToString:@"float2"])
    {
        return {MTLVertexFormatFloat2, 8};
    }
    if ([name isEqualToString:@"float3"])
    {
        return {MTLVertexFormatFloat3, 12};
    }
    if ([name isEqualToString:@"float4"])
    {
        return {MTLVertexFormatFloat4, 16};
    }
    if ([name isEqualToString:@"int"])
    {
        return {MTLVertexFormatInt, 4};
    }
    if ([name isEqualToString:@"int2"])
    {
        return {MTLVertexFormatInt2, 8};
    }
    if ([name isEqualToString:@"int3"])
    {
        return {MTLVertexFormatInt3, 12};
    }
    if ([name isEqualToString:@"int4"])
    {
        return {MTLVertexFormatInt4, 16};
    }
    if ([name isEqualToString:@"uint"])
    {
        return {MTLVertexFormatUInt, 4};
    }
    if ([name isEqualToString:@"uint2"])
    {
        return {MTLVertexFormatUInt2, 8};
    }
    if ([name isEqualToString:@"uint3"])
    {
        return {MTLVertexFormatUInt3, 12};
    }
    if ([name isEqualToString:@"uint4"])
    {
        return {MTLVertexFormatUInt4, 16};
    }
    if ([name isEqualToString:@"uchar4normalized"])
    {
        return {MTLVertexFormatUChar4Normalized, 4};
    }
    if ([name isEqualToString:@"ushort4"])
    {
        return {MTLVertexFormatUShort4, 8};
    }
    return {MTLVertexFormatInvalid, 0};
}

bool vertex_step_function(NSString* name, MTLVertexStepFunction* result)
{
    if ([name isEqualToString:@"constant"])
    {
        *result = MTLVertexStepFunctionConstant;
        return true;
    }
    if ([name isEqualToString:@"per_vertex"])
    {
        *result = MTLVertexStepFunctionPerVertex;
        return true;
    }
    if ([name isEqualToString:@"per_instance"])
    {
        *result = MTLVertexStepFunctionPerInstance;
        return true;
    }
    return false;
}

bool binding_access(NSString* name, MTLBindingAccess* result)
{
    if ([name isEqualToString:@"read_only"])
    {
        *result = MTLBindingAccessReadOnly;
        return true;
    }
    if ([name isEqualToString:@"read_write"])
    {
        *result = MTLBindingAccessReadWrite;
        return true;
    }
    if ([name isEqualToString:@"write_only"])
    {
        *result = MTLBindingAccessWriteOnly;
        return true;
    }
    return false;
}

NSString* binding_access_name(MTLBindingAccess access)
{
    switch (access)
    {
        case MTLBindingAccessReadOnly: return @"read_only";
        case MTLBindingAccessReadWrite: return @"read_write";
        case MTLBindingAccessWriteOnly: return @"write_only";
        default: return [NSString stringWithFormat:@"MTLBindingAccess(%lu)",
                                                    static_cast<unsigned long>(access)];
    }
}

bool texture_type(NSString* name, MTLTextureType* result)
{
    NSDictionary<NSString*, NSNumber*>* types = @{
        @"1d": @(MTLTextureType1D),
        @"1d_array": @(MTLTextureType1DArray),
        @"2d": @(MTLTextureType2D),
        @"2d_array": @(MTLTextureType2DArray),
        @"2d_multisample": @(MTLTextureType2DMultisample),
        @"cube": @(MTLTextureTypeCube),
        @"cube_array": @(MTLTextureTypeCubeArray),
        @"3d": @(MTLTextureType3D),
        @"2d_multisample_array": @(MTLTextureType2DMultisampleArray),
        @"texture_buffer": @(MTLTextureTypeTextureBuffer),
    };
    NSNumber* value = types[name];
    if (value == nil)
    {
        return false;
    }
    *result = static_cast<MTLTextureType>(value.unsignedIntegerValue);
    return true;
}

NSString* texture_type_name(MTLTextureType type)
{
    switch (type)
    {
        case MTLTextureType1D: return @"1d";
        case MTLTextureType1DArray: return @"1d_array";
        case MTLTextureType2D: return @"2d";
        case MTLTextureType2DArray: return @"2d_array";
        case MTLTextureType2DMultisample: return @"2d_multisample";
        case MTLTextureTypeCube: return @"cube";
        case MTLTextureTypeCubeArray: return @"cube_array";
        case MTLTextureType3D: return @"3d";
        case MTLTextureType2DMultisampleArray: return @"2d_multisample_array";
        case MTLTextureTypeTextureBuffer: return @"texture_buffer";
        default: return [NSString stringWithFormat:@"MTLTextureType(%lu)",
                                                    static_cast<unsigned long>(type)];
    }
}

bool data_type(NSString* name, MTLDataType* result)
{
    NSDictionary<NSString*, NSNumber*>* types = @{
        @"struct": @(MTLDataTypeStruct),
        @"array": @(MTLDataTypeArray),
        @"float": @(MTLDataTypeFloat),
        @"float2": @(MTLDataTypeFloat2),
        @"vec2": @(MTLDataTypeFloat2),
        @"float3": @(MTLDataTypeFloat3),
        @"vec3": @(MTLDataTypeFloat3),
        @"float4": @(MTLDataTypeFloat4),
        @"vec4": @(MTLDataTypeFloat4),
        @"float2x2": @(MTLDataTypeFloat2x2),
        @"mat2": @(MTLDataTypeFloat2x2),
        @"float2x3": @(MTLDataTypeFloat2x3),
        @"mat2x3": @(MTLDataTypeFloat2x3),
        @"float2x4": @(MTLDataTypeFloat2x4),
        @"mat2x4": @(MTLDataTypeFloat2x4),
        @"float3x2": @(MTLDataTypeFloat3x2),
        @"mat3x2": @(MTLDataTypeFloat3x2),
        @"float3x3": @(MTLDataTypeFloat3x3),
        @"mat3": @(MTLDataTypeFloat3x3),
        @"float3x4": @(MTLDataTypeFloat3x4),
        @"mat3x4": @(MTLDataTypeFloat3x4),
        @"float4x2": @(MTLDataTypeFloat4x2),
        @"mat4x2": @(MTLDataTypeFloat4x2),
        @"float4x3": @(MTLDataTypeFloat4x3),
        @"mat4x3": @(MTLDataTypeFloat4x3),
        @"float4x4": @(MTLDataTypeFloat4x4),
        @"mat4": @(MTLDataTypeFloat4x4),
        @"int": @(MTLDataTypeInt),
        @"int2": @(MTLDataTypeInt2),
        @"ivec2": @(MTLDataTypeInt2),
        @"int3": @(MTLDataTypeInt3),
        @"ivec3": @(MTLDataTypeInt3),
        @"int4": @(MTLDataTypeInt4),
        @"ivec4": @(MTLDataTypeInt4),
        @"uint": @(MTLDataTypeUInt),
        @"uint2": @(MTLDataTypeUInt2),
        @"uvec2": @(MTLDataTypeUInt2),
        @"uint3": @(MTLDataTypeUInt3),
        @"uvec3": @(MTLDataTypeUInt3),
        @"uint4": @(MTLDataTypeUInt4),
        @"uvec4": @(MTLDataTypeUInt4),
        @"short": @(MTLDataTypeShort),
        @"short2": @(MTLDataTypeShort2),
        @"short3": @(MTLDataTypeShort3),
        @"short4": @(MTLDataTypeShort4),
        @"ushort": @(MTLDataTypeUShort),
        @"ushort2": @(MTLDataTypeUShort2),
        @"ushort3": @(MTLDataTypeUShort3),
        @"ushort4": @(MTLDataTypeUShort4),
        @"char": @(MTLDataTypeChar),
        @"char2": @(MTLDataTypeChar2),
        @"char3": @(MTLDataTypeChar3),
        @"char4": @(MTLDataTypeChar4),
        @"uchar": @(MTLDataTypeUChar),
        @"uchar2": @(MTLDataTypeUChar2),
        @"uchar3": @(MTLDataTypeUChar3),
        @"uchar4": @(MTLDataTypeUChar4),
        @"bool": @(MTLDataTypeBool),
        @"bool2": @(MTLDataTypeBool2),
        @"bvec2": @(MTLDataTypeBool2),
        @"bool3": @(MTLDataTypeBool3),
        @"bvec3": @(MTLDataTypeBool3),
        @"bool4": @(MTLDataTypeBool4),
        @"bvec4": @(MTLDataTypeBool4),
        @"half": @(MTLDataTypeHalf),
        @"half2": @(MTLDataTypeHalf2),
        @"half3": @(MTLDataTypeHalf3),
        @"half4": @(MTLDataTypeHalf4),
    };
    NSNumber* value = types[name];
    if (value == nil)
    {
        return false;
    }
    *result = static_cast<MTLDataType>(value.unsignedIntegerValue);
    return true;
}

bool matrix_shape(NSString* name, NSUInteger* columns, NSUInteger* rows)
{
    NSDictionary<NSString*, NSArray<NSNumber*>*>* shapes = @{
        @"mat2": @[@2, @2],
        @"mat2x2": @[@2, @2],
        @"mat2x3": @[@2, @3],
        @"mat2x4": @[@2, @4],
        @"mat3x2": @[@3, @2],
        @"mat3": @[@3, @3],
        @"mat3x3": @[@3, @3],
        @"mat3x4": @[@3, @4],
        @"mat4x2": @[@4, @2],
        @"mat4x3": @[@4, @3],
        @"mat4": @[@4, @4],
        @"mat4x4": @[@4, @4],
    };
    NSArray<NSNumber*>* shape = shapes[name];
    if (shape == nil)
    {
        return false;
    }
    *columns = shape[0].unsignedIntegerValue;
    *rows = shape[1].unsignedIntegerValue;
    return true;
}

bool canonical_member_type(NSString* name)
{
    return [@[
        @"bool",
        @"float",
        @"int",
        @"uint",
        @"vec2",
        @"vec3",
        @"vec4",
        @"ivec2",
        @"ivec3",
        @"ivec4",
        @"uvec2",
        @"uvec3",
        @"uvec4",
        @"mat3",
        @"mat4",
    ] containsObject:name];
}

NSString* data_type_name(MTLDataType type)
{
    switch (type)
    {
        case MTLDataTypeStruct: return @"struct";
        case MTLDataTypeArray: return @"array";
        case MTLDataTypeFloat: return @"float";
        case MTLDataTypeFloat2: return @"float2";
        case MTLDataTypeFloat3: return @"float3";
        case MTLDataTypeFloat4: return @"float4";
        case MTLDataTypeFloat2x2: return @"float2x2";
        case MTLDataTypeFloat2x3: return @"float2x3";
        case MTLDataTypeFloat2x4: return @"float2x4";
        case MTLDataTypeFloat3x2: return @"float3x2";
        case MTLDataTypeFloat3x3: return @"float3x3";
        case MTLDataTypeFloat3x4: return @"float3x4";
        case MTLDataTypeFloat4x2: return @"float4x2";
        case MTLDataTypeFloat4x3: return @"float4x3";
        case MTLDataTypeFloat4x4: return @"float4x4";
        case MTLDataTypeHalf: return @"half";
        case MTLDataTypeHalf2: return @"half2";
        case MTLDataTypeHalf3: return @"half3";
        case MTLDataTypeHalf4: return @"half4";
        case MTLDataTypeInt: return @"int";
        case MTLDataTypeInt2: return @"int2";
        case MTLDataTypeInt3: return @"int3";
        case MTLDataTypeInt4: return @"int4";
        case MTLDataTypeUInt: return @"uint";
        case MTLDataTypeUInt2: return @"uint2";
        case MTLDataTypeUInt3: return @"uint3";
        case MTLDataTypeUInt4: return @"uint4";
        case MTLDataTypeShort: return @"short";
        case MTLDataTypeShort2: return @"short2";
        case MTLDataTypeShort3: return @"short3";
        case MTLDataTypeShort4: return @"short4";
        case MTLDataTypeUShort: return @"ushort";
        case MTLDataTypeUShort2: return @"ushort2";
        case MTLDataTypeUShort3: return @"ushort3";
        case MTLDataTypeUShort4: return @"ushort4";
        case MTLDataTypeChar: return @"char";
        case MTLDataTypeChar2: return @"char2";
        case MTLDataTypeChar3: return @"char3";
        case MTLDataTypeChar4: return @"char4";
        case MTLDataTypeUChar: return @"uchar";
        case MTLDataTypeUChar2: return @"uchar2";
        case MTLDataTypeUChar3: return @"uchar3";
        case MTLDataTypeUChar4: return @"uchar4";
        case MTLDataTypeBool: return @"bool";
        case MTLDataTypeBool2: return @"bool2";
        case MTLDataTypeBool3: return @"bool3";
        case MTLDataTypeBool4: return @"bool4";
        default: return [NSString stringWithFormat:@"MTLDataType(%lu)",
                                                    static_cast<unsigned long>(type)];
    }
}

bool is_spirv_cross_padding(NSString* name)
{
    if (![name hasPrefix:@"_m"] || ![name hasSuffix:@"_pad"] || name.length <= 6)
    {
        return false;
    }
    NSString* ordinal = [name substringWithRange:NSMakeRange(2, name.length - 6)];
    return [ordinal rangeOfCharacterFromSet:
                        [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location
        == NSNotFound;
}

NSString* binding_kind(MTLBindingType type)
{
    switch (type)
    {
        case MTLBindingTypeBuffer: return @"buffer";
        case MTLBindingTypeTexture: return @"texture";
        case MTLBindingTypeSampler: return @"sampler";
        default: return nil;
    }
}

bool binding_type(NSString* kind, MTLBindingType* result)
{
    if ([kind isEqualToString:@"buffer"])
    {
        *result = MTLBindingTypeBuffer;
        return true;
    }
    if ([kind isEqualToString:@"texture"])
    {
        *result = MTLBindingTypeTexture;
        return true;
    }
    if ([kind isEqualToString:@"sampler"])
    {
        *result = MTLBindingTypeSampler;
        return true;
    }
    return false;
}

NSString* binding_key(MTLBindingType type, NSUInteger index)
{
    return [NSString stringWithFormat:@"%ld:%lu",
                                      static_cast<long>(type),
                                      static_cast<unsigned long>(index)];
}

bool validate_type_descriptor(NSDictionary* descriptor,
                              NSString* path,
                              bool is_member,
                              NSUInteger depth,
                              NSString* __autoreleasing* error);

bool validate_member_array(NSArray* members,
                           NSString* path,
                           NSUInteger depth,
                           NSString* __autoreleasing* error)
{
    if (members.count == 0)
    {
        return reject(error, [NSString stringWithFormat:@"%@ must not be empty", path]);
    }
    NSMutableSet<NSString*>* names = [NSMutableSet set];
    for (NSUInteger index = 0; index < members.count; ++index)
    {
        NSString* member_path = [NSString stringWithFormat:@"%@[%lu]",
                                                           path,
                                                           static_cast<unsigned long>(index)];
        id value = members[index];
        if (![value isKindOfClass:[NSDictionary class]])
        {
            return reject(error,
                          [NSString stringWithFormat:@"%@ must be an object", member_path]);
        }
        NSDictionary* member = value;
        if (!validate_type_descriptor(member, member_path, true, depth, error))
        {
            return false;
        }
        NSString* name = member[@"name"];
        if ([names containsObject:name])
        {
            return reject(error,
                          [NSString stringWithFormat:@"%@ duplicates member name %@",
                                                     member_path,
                                                     name]);
        }
        [names addObject:name];
    }
    return true;
}

bool validate_type_descriptor(NSDictionary* descriptor,
                              NSString* path,
                              bool is_member,
                              NSUInteger depth,
                              NSString* __autoreleasing* error)
{
    if (depth > 16)
    {
        return reject(error,
                      [NSString stringWithFormat:@"%@ exceeds 16 nested type levels", path]);
    }

    NSArray<NSString*>* identity = is_member ? @[@"name", @"offset"] : @[];
    NSMutableArray<NSString*>* common_required = [identity mutableCopy];
    [common_required addObject:@"type"];
    NSArray<NSString*>* all_fields = @[
        @"name",
        @"offset",
        @"type",
        @"array_length",
        @"array_stride",
        @"element",
        @"members",
        @"matrix_stride",
        @"matrix_major",
    ];
    if (!validate_keys(descriptor, common_required, all_fields, path, error))
    {
        return false;
    }
    if (is_member)
    {
        if (require_string(descriptor, @"name", path, error) == nil)
        {
            return false;
        }
        NSUInteger offset = 0;
        if (!require_unsigned_integer(descriptor, @"offset", path, &offset, error))
        {
            return false;
        }
    }

    NSString* type_name = require_string(descriptor, @"type", path, error);
    if (type_name == nil)
    {
        return false;
    }
    if ([type_name isEqualToString:@"array"])
    {
        NSMutableArray<NSString*>* required = [common_required mutableCopy];
        [required addObjectsFromArray:@[@"array_length", @"array_stride", @"element"]];
        if (!validate_keys(descriptor, required, required, path, error))
        {
            return false;
        }
        NSUInteger length = 0;
        NSUInteger stride = 0;
        if (!require_unsigned_integer(descriptor,
                                      @"array_length",
                                      path,
                                      &length,
                                      error)
            || !require_unsigned_integer(descriptor,
                                         @"array_stride",
                                         path,
                                         &stride,
                                         error))
        {
            return false;
        }
        if (length == 0 || stride == 0)
        {
            return reject(error,
                          [NSString stringWithFormat:
                                        @"%@ array_length and array_stride must be greater than zero",
                                        path]);
        }
        NSDictionary* element = require_object(descriptor, @"element", path, error);
        return element != nil
            && validate_type_descriptor(element,
                                        [path stringByAppendingString:@".element"],
                                        false,
                                        depth + 1,
                                        error);
    }
    if ([type_name isEqualToString:@"struct"])
    {
        NSMutableArray<NSString*>* required = [common_required mutableCopy];
        [required addObject:@"members"];
        if (!validate_keys(descriptor, required, required, path, error))
        {
            return false;
        }
        NSArray* members = require_array(descriptor, @"members", path, error);
        return members != nil
            && validate_member_array(members,
                                     [path stringByAppendingString:@".members"],
                                     depth + 1,
                                     error);
    }

    NSUInteger columns = 0;
    NSUInteger rows = 0;
    if (matrix_shape(type_name, &columns, &rows))
    {
        if (![type_name isEqualToString:@"mat3"]
            && ![type_name isEqualToString:@"mat4"])
        {
            return reject(error,
                          [NSString stringWithFormat:
                                        @"%@.type is unsupported by the v1 matrix layout",
                                        path]);
        }
        NSMutableArray<NSString*>* required = [common_required mutableCopy];
        [required addObjectsFromArray:@[@"matrix_stride", @"matrix_major"]];
        if (!validate_keys(descriptor, required, required, path, error))
        {
            return false;
        }
        NSUInteger stride = 0;
        if (!require_unsigned_integer(descriptor,
                                      @"matrix_stride",
                                      path,
                                      &stride,
                                      error))
        {
            return false;
        }
        NSString* major = require_string(descriptor, @"matrix_major", path, error);
        if (major == nil || ![major isEqualToString:@"column"])
        {
            return reject(error,
                          [NSString stringWithFormat:
                                        @"%@.matrix_major must be column for the v1 matrix layout",
                                        path]);
        }
        if (stride != 16)
        {
            return reject(error,
                          [NSString stringWithFormat:
                                        @"%@.matrix_stride must be 16 for the v1 matrix layout",
                                        path]);
        }
    }
    else if (!validate_keys(descriptor, common_required, common_required, path, error))
    {
        return false;
    }
    MTLDataType unused = MTLDataTypeNone;
    if (!canonical_member_type(type_name)
        || !data_type(type_name, &unused)
        || unused == MTLDataTypeArray
        || unused == MTLDataTypeStruct)
    {
        return reject(error,
                      [NSString stringWithFormat:@"%@.type is unsupported: %@",
                                                 path,
                                                 type_name]);
    }
    return true;
}

bool validate_expected_arguments(NSDictionary* expected,
                                 NSString* __autoreleasing* error)
{
    if (!validate_keys(expected,
                       @[@"vertex", @"fragment"],
                       @[@"vertex", @"fragment"],
                       @"expected_arguments",
                       error))
    {
        return false;
    }

    for (NSString* stage in @[@"vertex", @"fragment"])
    {
        NSArray* arguments = require_array(expected, stage, @"expected_arguments", error);
        if (arguments == nil)
        {
            return false;
        }
        NSMutableSet<NSString*>* keys = [NSMutableSet set];
        NSMutableSet<NSString*>* metal_names = [NSMutableSet set];
        for (NSUInteger index = 0; index < arguments.count; ++index)
        {
            NSString* path = [NSString stringWithFormat:@"expected_arguments.%@[%lu]",
                                                        stage,
                                                        static_cast<unsigned long>(index)];
            id value = arguments[index];
            if (![value isKindOfClass:[NSDictionary class]])
            {
                return reject(error, [NSString stringWithFormat:@"%@ must be an object", path]);
            }
            NSDictionary* argument = value;
            if (!validate_keys(argument,
                               @[@"name", @"metal_name", @"kind", @"index"],
                               @[@"name",
                                 @"metal_name",
                                 @"kind",
                                 @"index",
                                 @"access",
                                 @"buffer_size",
                                 @"buffer_alignment",
                                 @"members",
                                 @"texture_type",
                                 @"texture_data_type",
                                 @"array_length",
                                 @"is_depth_texture"],
                               path,
                               error))
            {
                return false;
            }
            if (require_string(argument, @"name", path, error) == nil)
            {
                return false;
            }
            NSString* metal_name = require_string(argument,
                                                  @"metal_name",
                                                  path,
                                                  error);
            if (metal_name == nil)
            {
                return false;
            }
            if ([metal_names containsObject:metal_name])
            {
                return reject(error,
                              [NSString stringWithFormat:
                                            @"%@ duplicates native Metal name %@",
                                            path,
                                            metal_name]);
            }
            [metal_names addObject:metal_name];
            NSString* kind = require_string(argument, @"kind", path, error);
            MTLBindingType type = MTLBindingTypeBuffer;
            if (kind == nil)
            {
                return false;
            }
            if (!binding_type(kind, &type))
            {
                return reject(error,
                              [NSString stringWithFormat:
                                            @"%@.kind must be buffer, texture, or sampler", path]);
            }
            NSUInteger argument_index = 0;
            if (!require_unsigned_integer(argument,
                                          @"index",
                                          path,
                                          &argument_index,
                                          error))
            {
                return false;
            }
            NSUInteger maximum_index = type == MTLBindingTypeBuffer
                                         ? MAX_METAL_BUFFER_INDEX
                                         : (type == MTLBindingTypeTexture
                                                ? MAX_METAL_TEXTURE_INDEX
                                                : MAX_METAL_SAMPLER_INDEX);
            if (argument_index > maximum_index)
            {
                return reject(error,
                              [NSString stringWithFormat:
                                            @"%@.index exceeds the Metal %@ limit of %lu",
                                            path,
                                            kind,
                                            static_cast<unsigned long>(maximum_index)]);
            }
            NSString* key = binding_key(type, argument_index);
            if ([keys containsObject:key])
            {
                return reject(error,
                              [NSString stringWithFormat:
                                            @"%@ duplicates %@ binding index %lu",
                                            path,
                                            kind,
                                            static_cast<unsigned long>(argument_index)]);
            }
            [keys addObject:key];

            if (type == MTLBindingTypeBuffer)
            {
                if (!validate_keys(argument,
                                   @[@"name",
                                     @"metal_name",
                                     @"kind",
                                     @"index",
                                     @"access",
                                     @"buffer_size",
                                     @"buffer_alignment",
                                     @"members"],
                                   @[@"name",
                                     @"metal_name",
                                     @"kind",
                                     @"index",
                                     @"access",
                                     @"buffer_size",
                                     @"buffer_alignment",
                                     @"members"],
                                   path,
                                   error))
                {
                    return false;
                }
                NSString* access_name = require_string(argument, @"access", path, error);
                MTLBindingAccess unused_access = MTLBindingAccessReadOnly;
                if (access_name == nil)
                {
                    return false;
                }
                if (!binding_access(access_name, &unused_access))
                {
                    return reject(error,
                                  [NSString stringWithFormat:
                                                @"%@.access must be read_only, read_write, or write_only",
                                                path]);
                }
                NSUInteger unused_size = 0;
                if (!require_unsigned_integer(argument,
                                              @"buffer_size",
                                              path,
                                              &unused_size,
                                              error))
                {
                    return false;
                }
                NSUInteger alignment = 0;
                if (!require_unsigned_integer(argument,
                                              @"buffer_alignment",
                                              path,
                                              &alignment,
                                              error))
                {
                    return false;
                }
                if (alignment == 0)
                {
                    return reject(error,
                                  [NSString stringWithFormat:
                                                @"%@.buffer_alignment must be greater than zero",
                                                path]);
                }
                NSArray* members = require_array(argument, @"members", path, error);
                if (members == nil
                    || !validate_member_array(members,
                                              [path stringByAppendingString:@".members"],
                                              0,
                                              error))
                {
                    return false;
                }
            }
            else if (type == MTLBindingTypeTexture)
            {
                NSArray<NSString*>* texture_fields = @[
                    @"name",
                    @"metal_name",
                    @"kind",
                    @"index",
                    @"access",
                    @"texture_type",
                    @"texture_data_type",
                    @"array_length",
                    @"is_depth_texture",
                ];
                if (!validate_keys(argument,
                                   texture_fields,
                                   texture_fields,
                                   path,
                                   error))
                {
                    return false;
                }
                NSString* access_name = require_string(argument, @"access", path, error);
                MTLBindingAccess unused_access = MTLBindingAccessReadOnly;
                if (access_name == nil)
                {
                    return false;
                }
                if (!binding_access(access_name, &unused_access))
                {
                    return reject(error,
                                  [NSString stringWithFormat:
                                                @"%@.access must be read_only, read_write, or write_only",
                                                path]);
                }
                NSString* type_name = require_string(argument,
                                                     @"texture_type",
                                                     path,
                                                     error);
                MTLTextureType unused_texture_type = MTLTextureType2D;
                if (type_name == nil)
                {
                    return false;
                }
                if (!texture_type(type_name, &unused_texture_type))
                {
                    return reject(error,
                                  [NSString stringWithFormat:
                                                @"%@.texture_type is unsupported: %@",
                                                path,
                                                type_name]);
                }
                NSString* data_type_name = require_string(argument,
                                                          @"texture_data_type",
                                                          path,
                                                          error);
                MTLDataType unused_data_type = MTLDataTypeNone;
                if (data_type_name == nil)
                {
                    return false;
                }
                if (!data_type(data_type_name, &unused_data_type)
                    || (unused_data_type != MTLDataTypeFloat
                        && unused_data_type != MTLDataTypeHalf
                        && unused_data_type != MTLDataTypeInt
                        && unused_data_type != MTLDataTypeUInt))
                {
                    return reject(error,
                                  [NSString stringWithFormat:
                                                @"%@.texture_data_type must be float, half, int, or uint",
                                                path]);
                }
                NSUInteger array_length = 0;
                if (!require_unsigned_integer(argument,
                                              @"array_length",
                                              path,
                                              &array_length,
                                              error))
                {
                    return false;
                }
                if (array_length == 0)
                {
                    return reject(error,
                                  [NSString stringWithFormat:
                                                @"%@.array_length must be greater than zero",
                                                path]);
                }
                BOOL unused_depth = NO;
                if (!require_boolean(argument,
                                     @"is_depth_texture",
                                     path,
                                     &unused_depth,
                                     error))
                {
                    return false;
                }
            }
            else if (!validate_keys(argument,
                                    @[@"name", @"metal_name", @"kind", @"index"],
                                    @[@"name", @"metal_name", @"kind", @"index"],
                                    path,
                                    error))
            {
                return false;
            }
        }
    }
    return true;
}

bool validate_selection_settings(NSArray* settings,
                                 bool boolean_values,
                                 NSMutableSet<NSString*>* names,
                                 NSString* path,
                                 NSString* __autoreleasing* error)
{
    NSString* previous_name = nil;
    for (NSUInteger index = 0; index < settings.count; ++index)
    {
        NSString* item_path = [NSString stringWithFormat:@"%@[%lu]",
                                                         path,
                                                         static_cast<unsigned long>(index)];
        id value = settings[index];
        if (![value isKindOfClass:[NSDictionary class]])
        {
            return reject(error,
                          [NSString stringWithFormat:@"%@ must be an object", item_path]);
        }
        NSDictionary* setting = value;
        if (!validate_keys(setting,
                           @[@"name", @"value"],
                           @[@"name", @"value"],
                           item_path,
                           error))
        {
            return false;
        }
        NSString* name = require_string(setting, @"name", item_path, error);
        if (name == nil || !is_identifier(name))
        {
            return reject(error,
                          [NSString stringWithFormat:@"%@.name must be an identifier",
                                                     item_path]);
        }
        if (previous_name != nil && [previous_name compare:name] != NSOrderedAscending)
        {
            return reject(error,
                          [NSString stringWithFormat:
                                        @"%@ must be strictly ordered by setting name",
                                        path]);
        }
        if ([names containsObject:name])
        {
            return reject(error,
                          [NSString stringWithFormat:
                                        @"selection setting name appears more than once: %@",
                                        name]);
        }
        [names addObject:name];
        previous_name = name;

        if (boolean_values)
        {
            BOOL unused = NO;
            if (!require_boolean(setting, @"value", item_path, &unused, error))
            {
                return false;
            }
        }
        else
        {
            std::int32_t unused = 0;
            if (!signed_32_integer(setting[@"value"], &unused))
            {
                return reject(error,
                              [NSString stringWithFormat:
                                            @"%@.value must be a signed 32-bit integer",
                                            item_path]);
            }
        }
    }
    return true;
}

bool validate_selection(NSDictionary* selection,
                        NSString* program_id,
                        NSString* __autoreleasing* error)
{
    NSArray<NSString*>* fields = @[
        @"source_symbol",
        @"source_index",
        @"shader_class",
        @"boolean_settings",
        @"integer_settings",
    ];
    if (!validate_keys(selection, fields, fields, @"pipeline spec.selection", error))
    {
        return false;
    }
    NSString* source_symbol = require_string(selection,
                                             @"source_symbol",
                                             @"pipeline spec.selection",
                                             error);
    if (source_symbol == nil || !is_identifier(source_symbol))
    {
        return reject(error, @"pipeline spec.selection.source_symbol must be an identifier");
    }

    id source_index_value = selection[@"source_index"];
    NSUInteger source_index = 0;
    bool has_source_index = source_index_value != [NSNull null];
    if (has_source_index
        && (!unsigned_integer(source_index_value, &source_index)
            || source_index > std::numeric_limits<std::uint16_t>::max()))
    {
        return reject(error,
                      @"pipeline spec.selection.source_index must be null or an unsigned 16-bit integer");
    }
    NSUInteger shader_class = 0;
    if (!require_unsigned_integer(selection,
                                  @"shader_class",
                                  @"pipeline spec.selection",
                                  &shader_class,
                                  error)
        || shader_class < 1 || shader_class > 3)
    {
        return reject(error,
                      @"pipeline spec.selection.shader_class must be in [1, 3]");
    }

    NSArray* boolean_settings = require_array(selection,
                                              @"boolean_settings",
                                              @"pipeline spec.selection",
                                              error);
    NSArray* integer_settings = require_array(selection,
                                              @"integer_settings",
                                              @"pipeline spec.selection",
                                              error);
    if (boolean_settings == nil || integer_settings == nil)
    {
        return false;
    }
    NSMutableSet<NSString*>* setting_names = [NSMutableSet set];
    if (!validate_selection_settings(boolean_settings,
                                     true,
                                     setting_names,
                                     @"pipeline spec.selection.boolean_settings",
                                     error)
        || !validate_selection_settings(integer_settings,
                                        false,
                                        setting_names,
                                        @"pipeline spec.selection.integer_settings",
                                        error))
    {
        return false;
    }

    NSDictionary<NSString*, NSNumber*>* fxaa_indices = @{
        @"fxaa_low": @0,
        @"fxaa_medium": @1,
        @"fxaa_high": @2,
        @"fxaa": @3,
    };
    NSDictionary<NSString*, NSNumber*>* smaa_indices = @{
        @"smaa_edge_low": @0,
        @"smaa_edge_medium": @1,
        @"smaa_edge_high": @2,
        @"smaa_edge_ultra": @3,
        @"smaa_weights_low": @0,
        @"smaa_weights_medium": @1,
        @"smaa_weights_high": @2,
        @"smaa_weights_ultra": @3,
        @"smaa_neighborhood_low": @0,
        @"smaa_neighborhood_medium": @1,
        @"smaa_neighborhood_high": @2,
        @"smaa_neighborhood_ultra": @3,
    };
    NSDictionary<NSString*, NSString*>* smaa_symbols = @{
        @"smaa_edge_low": @"gSMAAEdgeDetectProgram",
        @"smaa_edge_medium": @"gSMAAEdgeDetectProgram",
        @"smaa_edge_high": @"gSMAAEdgeDetectProgram",
        @"smaa_edge_ultra": @"gSMAAEdgeDetectProgram",
        @"smaa_weights_low": @"gSMAABlendWeightsProgram",
        @"smaa_weights_medium": @"gSMAABlendWeightsProgram",
        @"smaa_weights_high": @"gSMAABlendWeightsProgram",
        @"smaa_weights_ultra": @"gSMAABlendWeightsProgram",
        @"smaa_neighborhood_low": @"gSMAANeighborhoodBlendProgram",
        @"smaa_neighborhood_medium": @"gSMAANeighborhoodBlendProgram",
        @"smaa_neighborhood_high": @"gSMAANeighborhoodBlendProgram",
        @"smaa_neighborhood_ultra": @"gSMAANeighborhoodBlendProgram",
    };
    NSNumber* expected_fxaa_index = fxaa_indices[program_id];
    NSNumber* expected_smaa_index = smaa_indices[program_id];
    NSString* expected_smaa_symbol = smaa_symbols[program_id];
    if ([source_symbol isEqualToString:@"gFXAAProgram"])
    {
        if (expected_fxaa_index == nil || !has_source_index
            || source_index != expected_fxaa_index.unsignedIntegerValue
            || shader_class != 3 || boolean_settings.count != 0
            || integer_settings.count != 2)
        {
            return reject(error,
                          @"pipeline spec.selection does not match the exact FXAA source mapping");
        }
        NSDictionary* samples = integer_settings[0];
        NSDictionary* type = integer_settings[1];
        std::int32_t samples_value = -1;
        std::int32_t type_value = -1;
        if (![samples[@"name"] isEqualToString:@"RenderFSAASamples"]
            || ![type[@"name"] isEqualToString:@"RenderFSAAType"]
            || !signed_32_integer(samples[@"value"], &samples_value)
            || !signed_32_integer(type[@"value"], &type_value)
            || samples_value != static_cast<std::int32_t>(source_index)
            || type_value != 1)
        {
            return reject(error,
                          @"pipeline spec.selection does not match the exact FXAA settings mapping");
        }
    }
    else if ([source_symbol isEqualToString:@"gSMAAEdgeDetectProgram"]
             || [source_symbol isEqualToString:@"gSMAABlendWeightsProgram"]
             || [source_symbol isEqualToString:@"gSMAANeighborhoodBlendProgram"])
    {
        if (expected_smaa_index == nil || expected_smaa_symbol == nil
            || ![source_symbol isEqualToString:expected_smaa_symbol]
            || !has_source_index
            || source_index != expected_smaa_index.unsignedIntegerValue
            || shader_class != 3 || boolean_settings.count != 0
            || integer_settings.count != 2)
        {
            return reject(error,
                          @"pipeline spec.selection does not match the exact SMAA source mapping");
        }
        NSDictionary* samples = integer_settings[0];
        NSDictionary* type = integer_settings[1];
        std::int32_t samples_value = -1;
        std::int32_t type_value = -1;
        if (![samples[@"name"] isEqualToString:@"RenderFSAASamples"]
            || ![type[@"name"] isEqualToString:@"RenderFSAAType"]
            || !signed_32_integer(samples[@"value"], &samples_value)
            || !signed_32_integer(type[@"value"], &type_value)
            || samples_value != static_cast<std::int32_t>(source_index)
            || type_value != 2)
        {
            return reject(error,
                          @"pipeline spec.selection does not match the exact SMAA settings mapping");
        }
    }
    else if (has_source_index)
    {
        return reject(error,
                      @"pipeline spec.selection scalar source_symbol requires a null source_index");
    }
    else if (expected_fxaa_index != nil)
    {
        return reject(error,
                      @"pipeline spec.selection FXAA id requires gFXAAProgram");
    }
    else if (expected_smaa_index != nil)
    {
        return reject(error,
                      @"pipeline spec.selection SMAA id requires its exact source symbol");
    }
    return true;
}

bool is_bundled_program_id(NSString* program_id)
{
    return [program_id isEqualToString:@"avatar_skinning"]
        || [program_id isEqualToString:@"deferred_diffuse"]
        || [program_id isEqualToString:@"depth_copy"]
        || [program_id isEqualToString:@"fxaa"]
        || [program_id isEqualToString:@"fxaa_high"]
        || [program_id isEqualToString:@"fxaa_low"]
        || [program_id isEqualToString:@"fxaa_medium"]
        || [program_id isEqualToString:@"indexed_material"]
        || [program_id isEqualToString:@"pbr_alpha"]
        || [program_id isEqualToString:@"pbr_opaque"]
        || [program_id isEqualToString:@"presentation_copy"]
        || [program_id isEqualToString:@"reflection_probe"]
        || [program_id isEqualToString:@"shadow_alpha_mask"]
        || [program_id isEqualToString:@"shadow_alpha_receiver"]
        || [program_id isEqualToString:@"smaa_edge_high"]
        || [program_id isEqualToString:@"smaa_edge_low"]
        || [program_id isEqualToString:@"smaa_edge_medium"]
        || [program_id isEqualToString:@"smaa_edge_ultra"]
        || [program_id isEqualToString:@"smaa_neighborhood_high"]
        || [program_id isEqualToString:@"smaa_neighborhood_low"]
        || [program_id isEqualToString:@"smaa_neighborhood_medium"]
        || [program_id isEqualToString:@"smaa_neighborhood_ultra"]
        || [program_id isEqualToString:@"smaa_weights_high"]
        || [program_id isEqualToString:@"smaa_weights_low"]
        || [program_id isEqualToString:@"smaa_weights_medium"]
        || [program_id isEqualToString:@"smaa_weights_ultra"]
        || [program_id isEqualToString:@"terrain"]
        || [program_id isEqualToString:@"ui_font"];
}

bool is_selector_free_program_id(NSString* program_id)
{
    return [program_id isEqualToString:@"fxaa_depth_write"]
        || [program_id isEqualToString:@"indexed_material_stress_16"];
}

bool validate_spec(NSDictionary* spec, NSString* __autoreleasing* error)
{
    NSArray<NSString*>* fields = @[
        @"schema",
        @"id",
        @"metallib",
        @"vertex_function",
        @"fragment_function",
        @"color_formats",
        @"depth_format",
        @"sample_count",
        @"vertex_attributes",
        @"vertex_layouts",
        @"expected_arguments",
        @"selection",
    ];
    NSMutableArray<NSString*>* required_fields = [fields mutableCopy];
    [required_fields removeObject:@"depth_format"];
    [required_fields removeObject:@"selection"];
    if (!validate_keys(spec, required_fields, fields, @"pipeline spec", error))
    {
        return false;
    }

    NSUInteger schema = 0;
    if (!require_unsigned_integer(spec, @"schema", @"pipeline spec", &schema, error))
    {
        return false;
    }
    if (schema != 4 && schema != 5)
    {
        return reject(error, @"pipeline spec.schema must be 4 or 5");
    }
    NSString* program_id = require_string(spec, @"id", @"pipeline spec", error);
    if (program_id == nil)
    {
        return false;
    }
    const bool bundled_program = is_bundled_program_id(program_id);
    const bool selector_free_program = is_selector_free_program_id(program_id);
    if (!bundled_program && !selector_free_program)
    {
        return reject(error, @"pipeline spec.id is not in the frozen program inventory");
    }
    if ((bundled_program && schema != 5) || (selector_free_program && schema != 4))
    {
        return reject(error,
                      bundled_program
                          ? @"bundled pipeline spec requires schema 5 selection"
                          : @"selector-free pipeline spec requires schema 4");
    }

    for (NSString* key in @[@"metallib", @"vertex_function", @"fragment_function"])
    {
        if (require_string(spec, key, @"pipeline spec", error) == nil)
        {
            return false;
        }
    }
    id selection_value = spec[@"selection"];
    if (schema == 4)
    {
        if (selection_value != nil)
        {
            return reject(error, @"pipeline spec schema 4 must not contain selection");
        }
    }
    else
    {
        if (![selection_value isKindOfClass:[NSDictionary class]])
        {
            return reject(error, @"pipeline spec schema 5 requires selection");
        }
        if (!validate_selection(selection_value, program_id, error))
        {
            return false;
        }
    }

    NSArray* colors = require_array(spec, @"color_formats", @"pipeline spec", error);
    if (colors == nil)
    {
        return false;
    }
    if (colors.count > 8)
    {
        return reject(error, @"pipeline spec.color_formats exceeds eight attachments");
    }
    for (NSUInteger index = 0; index < colors.count; ++index)
    {
        id color = colors[index];
        if (![color isKindOfClass:[NSString class]]
            || pixel_format(color) == MTLPixelFormatInvalid
            || [color isEqualToString:@"depth32float"])
        {
            return reject(error,
                          [NSString stringWithFormat:
                                        @"pipeline spec.color_formats[%lu] is unsupported",
                                        static_cast<unsigned long>(index)]);
        }
    }
    id depth = spec[@"depth_format"];
    if (depth != nil && depth != [NSNull null]
        && (![depth isKindOfClass:[NSString class]]
            || pixel_format(depth) != MTLPixelFormatDepth32Float))
    {
        return reject(error,
                      @"pipeline spec.depth_format must be null or depth32float");
    }
    NSUInteger sample_count = 0;
    if (!require_unsigned_integer(spec,
                                  @"sample_count",
                                  @"pipeline spec",
                                  &sample_count,
                                  error))
    {
        return false;
    }
    if (sample_count == 0)
    {
        return reject(error, @"pipeline spec.sample_count must be greater than zero");
    }

    NSArray* attributes = require_array(spec,
                                        @"vertex_attributes",
                                        @"pipeline spec",
                                        error);
    NSArray* layouts = require_array(spec, @"vertex_layouts", @"pipeline spec", error);
    if (attributes == nil || layouts == nil)
    {
        return false;
    }
    NSMutableSet<NSNumber*>* locations = [NSMutableSet set];
    NSMutableSet<NSString*>* attribute_names = [NSMutableSet set];
    NSMutableDictionary<NSNumber*, NSNumber*>* required_ends = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSDictionary*>* attributes_by_name =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSMutableArray<NSString*>*>* names_by_buffer =
        [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index < attributes.count; ++index)
    {
        NSString* path = [NSString stringWithFormat:@"vertex_attributes[%lu]",
                                                    static_cast<unsigned long>(index)];
        id value = attributes[index];
        if (![value isKindOfClass:[NSDictionary class]])
        {
            return reject(error, [NSString stringWithFormat:@"%@ must be an object", path]);
        }
        NSDictionary* attribute = value;
        NSArray<NSString*>* fields = @[@"name", @"location", @"format", @"offset", @"buffer_index"];
        if (!validate_keys(attribute, fields, fields, path, error))
        {
            return false;
        }
        NSString* name = require_string(attribute, @"name", path, error);
        NSString* format_name = require_string(attribute, @"format", path, error);
        if (name == nil || format_name == nil)
        {
            return false;
        }
        if ([attribute_names containsObject:name])
        {
            return reject(error,
                          [NSString stringWithFormat:@"%@ duplicates attribute name %@",
                                                     path,
                                                     name]);
        }
        [attribute_names addObject:name];
        attributes_by_name[name] = attribute;
        NSUInteger location = 0;
        NSUInteger offset = 0;
        NSUInteger buffer_index = 0;
        if (!require_unsigned_integer(attribute, @"location", path, &location, error)
            || !require_unsigned_integer(attribute, @"offset", path, &offset, error)
            || !require_unsigned_integer(attribute,
                                         @"buffer_index",
                                         path,
                                         &buffer_index,
                                         error))
        {
            return false;
        }
        if (location >= MAX_VERTEX_ATTRIBUTES)
        {
            return reject(error,
                          [NSString stringWithFormat:@"%@.location must be less than %lu",
                                                     path,
                                                     static_cast<unsigned long>(
                                                         MAX_VERTEX_ATTRIBUTES)]);
        }
        if (buffer_index >= MAX_VERTEX_BUFFERS)
        {
            return reject(error,
                          [NSString stringWithFormat:@"%@.buffer_index must be less than %lu",
                                                     path,
                                                     static_cast<unsigned long>(MAX_VERTEX_BUFFERS)]);
        }
        NSNumber* boxed_location = @(location);
        if ([locations containsObject:boxed_location])
        {
            return reject(error,
                          [NSString stringWithFormat:@"%@ duplicates location %lu",
                                                     path,
                                                     static_cast<unsigned long>(location)]);
        }
        [locations addObject:boxed_location];
        VertexFormat format = vertex_format(format_name);
        if (format.format == MTLVertexFormatInvalid)
        {
            return reject(error,
                          [NSString stringWithFormat:@"%@.format is unsupported: %@",
                                                     path,
                                                     format_name]);
        }
        if (offset > std::numeric_limits<NSUInteger>::max() - format.size)
        {
            return reject(error, [NSString stringWithFormat:@"%@.offset overflows", path]);
        }
        NSNumber* buffer = @(buffer_index);
        if (names_by_buffer[buffer] == nil)
        {
            names_by_buffer[buffer] = [NSMutableArray array];
        }
        [names_by_buffer[buffer] addObject:name];
        NSUInteger required_end = offset + format.size;
        required_ends[buffer] = @(MAX(required_ends[buffer].unsignedIntegerValue,
                                     required_end));
    }

    NSArray<NSNumber*>* sorted_buffers = [[names_by_buffer allKeys]
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber* buffer in sorted_buffers)
    {
        NSArray<NSString*>* names = names_by_buffer[buffer];
        if (names.count > 1
            && ![[NSSet setWithArray:names]
                isEqualToSet:[NSSet setWithArray:@[@"position", @"texture_index"]]])
        {
            return reject(error,
                          [NSString stringWithFormat:
                                        @"vertex buffer %@ combines %@; Firestorm vertex data is SoA except for the position.w texture_index alias",
                                        buffer,
                                        [names componentsJoinedByString:@", "]]);
        }
    }
    NSDictionary* texture_index = attributes_by_name[@"texture_index"];
    if (texture_index != nil)
    {
        // Firestorm stores this integer in the fourth word of the float3 position
        // stream. The PSO decides whether its signedness matches the translated MSL.
        NSDictionary* position = attributes_by_name[@"position"];
        if (position == nil
            || ![texture_index[@"buffer_index"] isEqual:position[@"buffer_index"]]
            || [texture_index[@"offset"] unsignedIntegerValue]
                != [position[@"offset"] unsignedIntegerValue] + 12
            || ![position[@"format"] isEqualToString:@"float3"]
            || (![texture_index[@"format"] isEqualToString:@"int"]
                && ![texture_index[@"format"] isEqualToString:@"uint"]))
        {
            return reject(error,
                          @"texture_index must be a 32-bit integer alias of position.w in the same float3 position stream");
        }
    }

    NSMutableSet<NSNumber*>* layout_buffers = [NSMutableSet set];
    NSMutableDictionary<NSNumber*, NSNumber*>* layout_strides =
        [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index < layouts.count; ++index)
    {
        NSString* path = [NSString stringWithFormat:@"vertex_layouts[%lu]",
                                                    static_cast<unsigned long>(index)];
        id value = layouts[index];
        if (![value isKindOfClass:[NSDictionary class]])
        {
            return reject(error, [NSString stringWithFormat:@"%@ must be an object", path]);
        }
        NSDictionary* layout = value;
        NSArray<NSString*>* fields = @[@"buffer_index", @"stride", @"step_function"];
        if (!validate_keys(layout, fields, fields, path, error))
        {
            return false;
        }
        NSUInteger buffer_index = 0;
        NSUInteger stride = 0;
        if (!require_unsigned_integer(layout,
                                      @"buffer_index",
                                      path,
                                      &buffer_index,
                                      error)
            || !require_unsigned_integer(layout, @"stride", path, &stride, error))
        {
            return false;
        }
        if (buffer_index >= MAX_VERTEX_BUFFERS)
        {
            return reject(error,
                          [NSString stringWithFormat:@"%@.buffer_index must be less than %lu",
                                                     path,
                                                     static_cast<unsigned long>(MAX_VERTEX_BUFFERS)]);
        }
        if (stride == 0)
        {
            return reject(error,
                          [NSString stringWithFormat:@"%@.stride must be greater than zero", path]);
        }
        NSString* step_name = require_string(layout, @"step_function", path, error);
        MTLVertexStepFunction unused = MTLVertexStepFunctionPerVertex;
        if (step_name == nil)
        {
            return false;
        }
        if (!vertex_step_function(step_name, &unused))
        {
            return reject(error,
                          [NSString stringWithFormat:
                                        @"%@.step_function must be constant, per_vertex, or per_instance",
                                        path]);
        }
        NSNumber* buffer = @(buffer_index);
        if ([layout_buffers containsObject:buffer])
        {
            return reject(error,
                          [NSString stringWithFormat:@"%@ duplicates buffer_index %lu",
                                                     path,
                                                     static_cast<unsigned long>(buffer_index)]);
        }
        [layout_buffers addObject:buffer];
        layout_strides[buffer] = @(stride);
        NSNumber* required_end = required_ends[buffer];
        if (required_end == nil)
        {
            return reject(error,
                          [NSString stringWithFormat:
                                        @"%@ describes a buffer with no vertex attributes", path]);
        }
        if (required_end.unsignedIntegerValue > stride)
        {
            return reject(error,
                          [NSString stringWithFormat:
                                        @"%@.stride %lu is smaller than the required attribute extent %lu",
                                        path,
                                        static_cast<unsigned long>(stride),
                                        static_cast<unsigned long>(required_end.unsignedIntegerValue)]);
        }
    }
    if (![layout_buffers isEqualToSet:[NSSet setWithArray:required_ends.allKeys]])
    {
        return reject(error,
                      @"vertex_layouts must describe every referenced vertex buffer exactly once");
    }
    if (texture_index != nil
        && layout_strides[texture_index[@"buffer_index"]].unsignedIntegerValue != 16)
    {
        return reject(error,
                      @"the shared position and texture_index vertex stream must have stride 16");
    }

    NSDictionary* expected = require_object(spec,
                                            @"expected_arguments",
                                            @"pipeline spec",
                                            error);
    if (expected == nil || !validate_expected_arguments(expected, error))
    {
        return false;
    }
    for (NSDictionary* argument in expected[@"vertex"])
    {
        if ([argument[@"kind"] isEqualToString:@"buffer"])
        {
            NSNumber* index = argument[@"index"];
            if ([layout_buffers containsObject:index])
            {
                return reject(error,
                              [NSString stringWithFormat:
                                            @"vertex argument %@ collides with vertex buffer index %@",
                                            argument[@"name"],
                                            index]);
            }
        }
    }
    return true;
}

bool configure_vertex_descriptor(NSDictionary* spec,
                                 MTLRenderPipelineDescriptor* descriptor,
                                 NSString* __autoreleasing* error)
{
    MTLVertexDescriptor* vertex_descriptor = [MTLVertexDescriptor vertexDescriptor];
    for (NSDictionary* attribute in spec[@"vertex_attributes"])
    {
        NSUInteger location = [attribute[@"location"] unsignedIntegerValue];
        VertexFormat format = vertex_format(attribute[@"format"]);
        vertex_descriptor.attributes[location].format = format.format;
        vertex_descriptor.attributes[location].offset =
            [attribute[@"offset"] unsignedIntegerValue];
        vertex_descriptor.attributes[location].bufferIndex =
            [attribute[@"buffer_index"] unsignedIntegerValue];
    }
    for (NSDictionary* layout in spec[@"vertex_layouts"])
    {
        NSUInteger buffer_index = [layout[@"buffer_index"] unsignedIntegerValue];
        MTLVertexStepFunction step_function = MTLVertexStepFunctionPerVertex;
        if (!vertex_step_function(layout[@"step_function"], &step_function))
        {
            return reject(error, @"validated vertex step function became invalid");
        }
        vertex_descriptor.layouts[buffer_index].stride =
            [layout[@"stride"] unsignedIntegerValue];
        vertex_descriptor.layouts[buffer_index].stepFunction = step_function;
        vertex_descriptor.layouts[buffer_index].stepRate = 1;
    }
    descriptor.vertexDescriptor = vertex_descriptor;
    return true;
}

NSString* describe_binding(id<MTLBinding> binding)
{
    NSString* kind = binding_kind(binding.type);
    if (kind == nil)
    {
        kind = [NSString stringWithFormat:@"MTLBindingType(%ld)",
                                          static_cast<long>(binding.type)];
    }
    return [NSString stringWithFormat:@"%@ %@[%lu] (used=%@, argument=%@)",
                                      binding.name,
                                      kind,
                                      static_cast<unsigned long>(binding.index),
                                      binding.isUsed ? @"true" : @"false",
                                      binding.isArgument ? @"true" : @"false"];
}

void validate_binding_access(NSDictionary* expected,
                             id<MTLBinding> binding,
                             NSString* label,
                             NSMutableArray<NSString*>* errors)
{
    MTLBindingAccess expected_access = MTLBindingAccessReadOnly;
    binding_access(expected[@"access"], &expected_access);
    if (binding.access != expected_access)
    {
        [errors addObject:[NSString
                              stringWithFormat:@"%@: access is %@, expected %@",
                                               label,
                                               binding_access_name(binding.access),
                                               expected[@"access"]]];
    }
}

void validate_reflected_type(NSDictionary* expected,
                             MTLDataType reflected_type,
                             MTLStructType* reflected_struct,
                             MTLArrayType* reflected_array,
                             NSString* label,
                             NSUInteger depth,
                             NSMutableArray<NSString*>* errors);

void validate_reflected_members(NSArray<NSDictionary*>* expected_members,
                                MTLStructType* structure,
                                NSString* label,
                                NSUInteger depth,
                                NSMutableArray<NSString*>* errors)
{
    if (structure == nil)
    {
        [errors addObject:[NSString stringWithFormat:
                                      @"%@: Metal did not provide struct reflection",
                                      label]];
        return;
    }

    NSMutableDictionary<NSString*, MTLStructMember*>* reflected =
        [NSMutableDictionary dictionary];
    for (MTLStructMember* member in structure.members)
    {
        if (reflected[member.name] != nil)
        {
            [errors addObject:[NSString stringWithFormat:
                                          @"%@: Metal returned duplicate member %@",
                                          label,
                                          member.name]];
        }
        reflected[member.name] = member;
    }

    for (NSDictionary* expected_member in expected_members)
    {
        NSString* name = expected_member[@"name"];
        NSString* member_label = [NSString stringWithFormat:@"%@ member %@", label, name];
        MTLStructMember* member = reflected[name];
        if (member == nil)
        {
            [errors addObject:[NSString stringWithFormat:@"%@: missing", member_label]];
            continue;
        }
        NSUInteger expected_offset = [expected_member[@"offset"] unsignedIntegerValue];
        if (member.offset != expected_offset)
        {
            [errors addObject:[NSString
                                  stringWithFormat:@"%@: offset is %lu, expected %lu",
                                                   member_label,
                                                   static_cast<unsigned long>(member.offset),
                                                   static_cast<unsigned long>(expected_offset)]];
        }
        validate_reflected_type(expected_member,
                                member.dataType,
                                member.structType,
                                member.arrayType,
                                member_label,
                                depth,
                                errors);
    }

    NSSet<NSString*>* expected_names = [NSSet setWithArray:
        [expected_members valueForKey:@"name"]];
    NSArray<NSString*>* reflected_names = [[reflected allKeys]
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSString* name in reflected_names)
    {
        if (![expected_names containsObject:name] && !is_spirv_cross_padding(name))
        {
            [errors addObject:[NSString stringWithFormat:@"%@: unexpected member %@",
                                                        label,
                                                        name]];
        }
    }
}

void validate_reflected_type(NSDictionary* expected,
                             MTLDataType reflected_type,
                             MTLStructType* reflected_struct,
                             MTLArrayType* reflected_array,
                             NSString* label,
                             NSUInteger depth,
                             NSMutableArray<NSString*>* errors)
{
    if (depth > 16)
    {
        [errors addObject:[NSString stringWithFormat:
                                      @"%@: internal recursion limit exceeded",
                                      label]];
        return;
    }

    NSString* expected_name = expected[@"type"];
    if ([expected_name isEqualToString:@"array"])
    {
        if (reflected_type != MTLDataTypeArray)
        {
            [errors addObject:[NSString stringWithFormat:@"%@: type is %@, expected array",
                                                        label,
                                                        data_type_name(reflected_type)]];
            return;
        }
        if (reflected_array == nil)
        {
            [errors addObject:[NSString stringWithFormat:
                                          @"%@: Metal did not provide array reflection",
                                          label]];
            return;
        }
        NSUInteger expected_length = [expected[@"array_length"] unsignedIntegerValue];
        if (reflected_array.arrayLength != expected_length)
        {
            [errors addObject:[NSString
                                  stringWithFormat:@"%@: array length is %lu, expected %lu",
                                                   label,
                                                   static_cast<unsigned long>(
                                                       reflected_array.arrayLength),
                                                   static_cast<unsigned long>(expected_length)]];
        }
        NSUInteger expected_stride = [expected[@"array_stride"] unsignedIntegerValue];
        if (reflected_array.stride != expected_stride)
        {
            [errors addObject:[NSString
                                  stringWithFormat:@"%@: array stride is %lu, expected %lu",
                                                   label,
                                                   static_cast<unsigned long>(reflected_array.stride),
                                                   static_cast<unsigned long>(expected_stride)]];
        }
        validate_reflected_type(expected[@"element"],
                                reflected_array.elementType,
                                reflected_array.elementStructType,
                                reflected_array.elementArrayType,
                                [label stringByAppendingString:@" element"],
                                depth + 1,
                                errors);
        return;
    }

    if ([expected_name isEqualToString:@"struct"])
    {
        if (reflected_type != MTLDataTypeStruct)
        {
            [errors addObject:[NSString stringWithFormat:@"%@: type is %@, expected struct",
                                                        label,
                                                        data_type_name(reflected_type)]];
            return;
        }
        validate_reflected_members(expected[@"members"],
                                   reflected_struct,
                                   label,
                                   depth + 1,
                                   errors);
        return;
    }

    MTLDataType expected_type = MTLDataTypeNone;
    data_type(expected_name, &expected_type);
    if (reflected_type != expected_type)
    {
        [errors addObject:[NSString stringWithFormat:@"%@: type is %@, expected %@",
                                                    label,
                                                    data_type_name(reflected_type),
                                                    expected_name]];
    }
}

void validate_buffer(NSDictionary* expected,
                     id<MTLBinding> binding,
                     NSString* stage,
                     NSMutableArray<NSString*>* errors)
{
    id<MTLBufferBinding> buffer = (id<MTLBufferBinding>)binding;
    NSString* label = [NSString stringWithFormat:@"%@ argument %@ (%@)",
                                                stage,
                                                expected[@"name"],
                                                describe_binding(binding)];
    validate_binding_access(expected, binding, label, errors);
    NSNumber* expected_size = expected[@"buffer_size"];
    if (expected_size != nil
        && buffer.bufferDataSize != expected_size.unsignedIntegerValue)
    {
        [errors addObject:[NSString
                              stringWithFormat:@"%@: buffer size is %lu, expected %lu",
                                               label,
                                               static_cast<unsigned long>(buffer.bufferDataSize),
                                               static_cast<unsigned long>(
                                                   expected_size.unsignedIntegerValue)]];
    }
    NSNumber* expected_alignment = expected[@"buffer_alignment"];
    if (expected_alignment != nil
        && buffer.bufferAlignment != expected_alignment.unsignedIntegerValue)
    {
        [errors addObject:[NSString
                              stringWithFormat:@"%@: buffer alignment is %lu, expected %lu",
                                               label,
                                               static_cast<unsigned long>(buffer.bufferAlignment),
                                               static_cast<unsigned long>(
                                                   expected_alignment.unsignedIntegerValue)]];
    }

    NSArray<NSDictionary*>* expected_members = expected[@"members"];
    if (expected_members == nil)
    {
        return;
    }
    validate_reflected_members(expected_members,
                               buffer.bufferStructType,
                               label,
                               0,
                               errors);
}

void validate_texture(NSDictionary* expected,
                      id<MTLBinding> binding,
                      NSString* stage,
                      NSMutableArray<NSString*>* errors)
{
    id<MTLTextureBinding> texture = (id<MTLTextureBinding>)binding;
    NSString* label = [NSString stringWithFormat:@"%@ argument %@ (%@)",
                                                stage,
                                                expected[@"name"],
                                                describe_binding(binding)];
    validate_binding_access(expected, binding, label, errors);

    MTLTextureType expected_type = MTLTextureType2D;
    texture_type(expected[@"texture_type"], &expected_type);
    if (texture.textureType != expected_type)
    {
        [errors addObject:[NSString stringWithFormat:@"%@: texture type is %@, expected %@",
                                                    label,
                                                    texture_type_name(texture.textureType),
                                                    expected[@"texture_type"]]];
    }
    MTLDataType expected_data_type = MTLDataTypeNone;
    data_type(expected[@"texture_data_type"], &expected_data_type);
    if (texture.textureDataType != expected_data_type)
    {
        [errors addObject:[NSString
                              stringWithFormat:@"%@: texture data type is %@, expected %@",
                                               label,
                                               data_type_name(texture.textureDataType),
                                               expected[@"texture_data_type"]]];
    }
    NSUInteger expected_length = [expected[@"array_length"] unsignedIntegerValue];
    if (texture.arrayLength != expected_length)
    {
        [errors addObject:[NSString
                              stringWithFormat:@"%@: array length is %lu, expected %lu",
                                               label,
                                               static_cast<unsigned long>(texture.arrayLength),
                                               static_cast<unsigned long>(expected_length)]];
    }
    BOOL expected_depth = [expected[@"is_depth_texture"] boolValue];
    if (texture.isDepthTexture != expected_depth)
    {
        [errors addObject:[NSString stringWithFormat:@"%@: depth texture is %@, expected %@",
                                                    label,
                                                    texture.isDepthTexture ? @"true" : @"false",
                                                    expected_depth ? @"true" : @"false"]];
    }
}

void validate_stage_arguments(NSArray<NSDictionary*>* expected,
                              NSArray<id<MTLBinding>>* reflected,
                              NSString* stage,
                              NSSet<NSNumber*>* expected_vertex_buffers,
                              NSMutableArray<NSString*>* errors)
{
    NSMutableDictionary<NSString*, id<MTLBinding>>* actual = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber*>* reflected_vertex_buffers = [NSMutableSet set];
    for (id<MTLBinding> binding in reflected)
    {
        if (!binding.isArgument)
        {
            NSNumber* index = @(binding.index);
            if ([stage isEqualToString:@"vertex"]
                && binding.type == MTLBindingTypeBuffer
                && [expected_vertex_buffers containsObject:index])
            {
                if ([reflected_vertex_buffers containsObject:index])
                {
                    [errors addObject:[NSString stringWithFormat:
                                                  @"vertex reflection has duplicate vertex buffer index %@",
                                                  index]];
                }
                [reflected_vertex_buffers addObject:index];
                if (!binding.isUsed)
                {
                    [errors addObject:[NSString stringWithFormat:
                                                  @"vertex buffer %@ matched an unused Metal %@",
                                                  index,
                                                  describe_binding(binding)]];
                }
            }
            else
            {
                [errors addObject:[NSString stringWithFormat:
                                              @"%@ has unexpected non-argument Metal %@",
                                              stage,
                                              describe_binding(binding)]];
            }
            continue;
        }
        NSString* key = binding_key(binding.type, binding.index);
        if (actual[key] != nil)
        {
            [errors addObject:[NSString stringWithFormat:
                                          @"%@ reflection has duplicate binding key for %@ and %@",
                                          stage,
                                          describe_binding(actual[key]),
                                          describe_binding(binding)]];
            continue;
        }
        actual[key] = binding;
    }

    if ([stage isEqualToString:@"vertex"]
        && ![reflected_vertex_buffers isEqualToSet:expected_vertex_buffers])
    {
        NSMutableSet<NSNumber*>* missing = [expected_vertex_buffers mutableCopy];
        [missing minusSet:reflected_vertex_buffers];
        if (missing.count != 0)
        {
            NSArray<NSNumber*>* sorted_missing = [[missing allObjects]
                sortedArrayUsingSelector:@selector(compare:)];
            [errors addObject:[NSString stringWithFormat:
                                          @"vertex reflection is missing vertex buffer indices %@",
                                          [sorted_missing componentsJoinedByString:@", "]]];
        }
    }

    NSMutableSet<NSString*>* matched = [NSMutableSet set];
    for (NSDictionary* argument in expected)
    {
        MTLBindingType type = MTLBindingTypeBuffer;
        binding_type(argument[@"kind"], &type);
        NSUInteger index = [argument[@"index"] unsignedIntegerValue];
        NSString* key = binding_key(type, index);
        id<MTLBinding> binding = actual[key];
        if (binding == nil)
        {
            [errors addObject:[NSString
                                  stringWithFormat:@"%@ argument %@: missing %@[%lu]",
                                                   stage,
                                                   argument[@"name"],
                                                   argument[@"kind"],
                                                   static_cast<unsigned long>(index)]];
            continue;
        }
        [matched addObject:key];
        if (![binding.name isEqualToString:argument[@"metal_name"]])
        {
            [errors addObject:[NSString stringWithFormat:
                                          @"%@ argument %@ expected Metal name %@, matched Metal name %@",
                                          stage,
                                          argument[@"name"],
                                          argument[@"metal_name"],
                                          binding.name]];
        }
        if (!binding.isUsed)
        {
            [errors addObject:[NSString stringWithFormat:
                                          @"%@ argument %@ matched an unused Metal %@",
                                          stage,
                                          argument[@"name"],
                                          describe_binding(binding)]];
        }
        if (type == MTLBindingTypeBuffer)
        {
            validate_buffer(argument, binding, stage, errors);
        }
        else if (type == MTLBindingTypeTexture)
        {
            validate_texture(argument, binding, stage, errors);
        }
    }

    NSArray<NSString*>* sorted_keys = [[actual allKeys]
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSString* key in sorted_keys)
    {
        if (![matched containsObject:key])
        {
            [errors addObject:[NSString stringWithFormat:@"%@ has unexpected Metal %@",
                                                        stage,
                                                        describe_binding(actual[key])]];
        }
    }
}

bool validate_reflection(NSDictionary* spec,
                         MTLRenderPipelineReflection* reflection,
                         NSArray<NSString*>* __autoreleasing* validation_errors)
{
    NSMutableArray<NSString*>* errors = [NSMutableArray array];
    if (reflection == nil)
    {
        [errors addObject:@"Metal returned no render pipeline reflection"];
    }
    else
    {
        NSDictionary* expected = spec[@"expected_arguments"];
        NSMutableSet<NSNumber*>* vertex_buffers = [NSMutableSet set];
        for (NSDictionary* layout in spec[@"vertex_layouts"])
        {
            [vertex_buffers addObject:layout[@"buffer_index"]];
        }
        validate_stage_arguments(expected[@"vertex"],
                                 reflection.vertexBindings,
                                 @"vertex",
                                 vertex_buffers,
                                 errors);
        validate_stage_arguments(expected[@"fragment"],
                                 reflection.fragmentBindings,
                                 @"fragment",
                                 [NSSet set],
                                 errors);
    }
    *validation_errors = errors;
    return errors.count == 0;
}
}

int main(int argc, const char* argv[])
{
    @autoreleasepool
    {
        if (argc != 2)
        {
            print_error(@"usage: validate_metal_pipeline PIPELINE_SPEC.json");
            return 2;
        }

        NSError* json_error = nil;
        NSString* spec_path = [NSString stringWithUTF8String:argv[1]];
        NSData* data = [NSData dataWithContentsOfFile:spec_path options:0 error:&json_error];
        if (data == nil)
        {
            print_error([NSString stringWithFormat:@"cannot read pipeline spec: %@", json_error]);
            return 2;
        }
        id document = [NSJSONSerialization JSONObjectWithData:data options:0 error:&json_error];
        if (![document isKindOfClass:[NSDictionary class]])
        {
            print_error([NSString stringWithFormat:@"invalid pipeline spec JSON: %@",
                                                   json_error ?: @"root is not an object"]);
            return 2;
        }
        NSDictionary* spec = document;
        NSString* spec_error = nil;
        if (!validate_spec(spec, &spec_error))
        {
            print_error([NSString stringWithFormat:@"invalid pipeline spec: %@", spec_error]);
            return 2;
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil)
        {
            print_error(@"no Metal device is available");
            return 3;
        }

        NSError* metal_error = nil;
        NSURL* library_url = [NSURL fileURLWithPath:spec[@"metallib"]];
        id<MTLLibrary> library = [device newLibraryWithURL:library_url error:&metal_error];
        if (library == nil)
        {
            print_error([NSString stringWithFormat:@"cannot load metallib: %@", metal_error]);
            return 3;
        }

        id<MTLFunction> vertex = [library newFunctionWithName:spec[@"vertex_function"]];
        id<MTLFunction> fragment = [library newFunctionWithName:spec[@"fragment_function"]];
        if (vertex == nil || fragment == nil ||
            vertex.functionType != MTLFunctionTypeVertex ||
            fragment.functionType != MTLFunctionTypeFragment)
        {
            print_error([NSString stringWithFormat:
                                      @"pipeline functions are missing or have the wrong stage (vertex %@: %@; fragment %@: %@)",
                                      spec[@"vertex_function"],
                                      vertex == nil ? @"missing" :
                                          (vertex.functionType == MTLFunctionTypeVertex ? @"vertex" : @"wrong stage"),
                                      spec[@"fragment_function"],
                                      fragment == nil ? @"missing" :
                                          (fragment.functionType == MTLFunctionTypeFragment ? @"fragment" : @"wrong stage")]);
            return 3;
        }

        MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.label = spec[@"id"];
        descriptor.vertexFunction = vertex;
        descriptor.fragmentFunction = fragment;
        descriptor.rasterSampleCount = [spec[@"sample_count"] unsignedIntegerValue];

        NSArray* color_formats = spec[@"color_formats"];
        for (NSUInteger index = 0; index < color_formats.count; ++index)
        {
            descriptor.colorAttachments[index].pixelFormat = pixel_format(color_formats[index]);
        }
        NSString* depth_format = spec[@"depth_format"];
        if ([depth_format isKindOfClass:[NSString class]])
        {
            descriptor.depthAttachmentPixelFormat = pixel_format(depth_format);
        }
        if (!configure_vertex_descriptor(spec, descriptor, &spec_error))
        {
            print_error([NSString stringWithFormat:@"invalid pipeline spec: %@", spec_error]);
            return 2;
        }

        MTLRenderPipelineReflection* reflection = nil;
        // BindingInfo is the macOS 13 replacement for ArgumentInfo and uses the
        // same option bit without Xcode 26's deprecation warning.
        MTLPipelineOption options =
            MTLPipelineOptionBindingInfo | MTLPipelineOptionBufferTypeInfo;
        id<MTLRenderPipelineState> pipeline =
            [device newRenderPipelineStateWithDescriptor:descriptor
                                                 options:options
                                              reflection:&reflection
                                                   error:&metal_error];
        if (pipeline == nil)
        {
            print_error([NSString stringWithFormat:@"pipeline creation failed: %@", metal_error]);
            return 3;
        }

        NSArray<NSString*>* reflection_errors = nil;
        if (!validate_reflection(spec, reflection, &reflection_errors))
        {
            for (NSString* message in reflection_errors)
            {
                print_error([NSString stringWithFormat:@"pipeline reflection failed: %@", message]);
            }
            return 4;
        }

        printf("pipeline and reflection OK: %s\n", [spec[@"id"] UTF8String]);
        return 0;
    }
}
